import Foundation
import ThrushCore

/// Manages a session's WebSocket attachments on its session actor.
final class WebSocketTransport {
    private typealias TransportError = SessionActor.TransportError

    private struct ServerControl: Decodable {
        enum Kind: String, Decodable { case ready, exit }
        let type: Kind
        let resumed: Bool?
    }

    private struct ClientControl: Encodable, Sendable {
        private enum Kind: String, Encodable { case resize, close }
        private let type: Kind
        private let cols: Int?
        private let rows: Int?

        static func resize(_ size: Terminal.Size) -> Self {
            Self(type: .resize, cols: size.columns, rows: size.rows)
        }

        static let close = Self(type: .close, cols: nil, rows: nil)
    }

    private struct HeldInput {
        let input: Terminal.Input
        let byteCount: Int
        let onWriteStarted: (@Sendable () -> Void)?
    }

    private let createTask: @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask
    private let onOutput: (@Sendable (Data) -> Void)?
    fileprivate let frameTrace: (any WebSocketFrameTrace)?
    private let sleepForRetry: @Sendable (Duration) async throws -> Void
    private var socket: URLSessionWebSocketTask?
    private var attachmentSize = Terminal.Size(columns: 80, rows: 24)
    private var retryWait: Task<Void, Error>?
    private var retryMilliseconds = 250
    private var pendingEvent: SessionActor.Event?
    private var recovering = false
    private var isReading = false
    private var heldInput: [HeldInput] = []
    private var heldBytes = 0

    fileprivate var socketAttempts = 0
    // The next binary after ready(resumed: true) is a replay, even if the app closes
    // the session before that binary arrives. A live replay replaces the active grid.
    private enum Replay { case resumed, live }
    private var nextReplay: Replay?
    fileprivate var awaitingReplay: Bool { nextReplay != nil }
    fileprivate var replacedPreviousShell = false
    fileprivate var discardedHeldInputOnLastReady = false

    init(onOutput: (@Sendable (Data) -> Void)?, frameTrace: (any WebSocketFrameTrace)?,
         sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.createTask = makeSocket
        self.onOutput = onOutput
        self.frameTrace = frameTrace
        self.sleepForRetry = sleepForRetry
    }

    deinit {
        retryWait?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Only the convenience endpoint owns a URLSession. An app's factory keeps its own.
    private final class DemoSession: Sendable {
        let session = URLSession(configuration: .ephemeral)
        deinit { session.invalidateAndCancel() }
    }

    convenience init(baseURL: URL, clientID: String, onOutput: (@Sendable (Data) -> Void)?,
                     frameTrace: (any WebSocketFrameTrace)?) throws {
        guard var location = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              location.host != nil, location.query == nil, location.fragment == nil
        else { throw URLError(.badURL) }
        switch location.scheme {
        case "http", "ws": location.scheme = "ws"
        case "https", "wss": location.scheme = "wss"
        default: throw URLError(.badURL)
        }
        location.path = baseURL.appending(path: "socket").path
        let endpoint = location
        precondition(!clientID.isEmpty, "A shell needs a stable client ID")
        let owner = DemoSession()
        self.init(onOutput: onOutput, frameTrace: frameTrace) { size in
            var location = endpoint
            location.queryItems = [
                URLQueryItem(name: "service", value: "terminal"),
                URLQueryItem(name: "clientId", value: clientID),
                URLQueryItem(name: "cols", value: String(size.columns)),
                URLQueryItem(name: "rows", value: String(size.rows)),
            ]
            // URLSearchParams on the server decodes an unescaped plus as a space.
            location.percentEncodedQuery = location.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = location.url else { throw URLError(.badURL) }
            let task = owner.session.webSocketTask(with: url)
            // A single repaint can include a thousand rows of colored history.
            task.maximumMessageSize = 64 * 1024 * 1024
            return task
        }
    }

    fileprivate func open(at size: Terminal.Size) -> SessionActor.State {
        socketAttempts += 1
        do {
            let next = try createTask(size)
            socket = next
            attachmentSize = size
            frameTrace?.record("open", attachment: socketAttempts)
            next.resume()
            return .connecting
        } catch {
            recovering = true
            pendingEvent = .reconnecting
            return .reconnecting
        }
    }

    func attach(to session: isolated SessionActor, userInitiated: Bool) -> Bool {
        guard session.beginOpening(userInitiated: userInitiated) else { return false }
        pendingEvent = nil
        isReading = false
        session.state = open(at: session.requestedSize)
        return true
    }

    func nextEvent(in session: isolated SessionActor) async throws -> SessionActor.Event {
        guard !isReading else { throw TransportError.concurrentRead }
        isReading = true
        let stamp = session.lifetime
        defer { if session.lifetime == stamp { isReading = false } }

        if let event = takePendingEvent() { return event }
        if session.state == .reconnecting {
            let delay = Duration.milliseconds(retryMilliseconds)
            retryMilliseconds = min(retryMilliseconds * 2, 4_000)
            let wait = Task { [sleepForRetry] in try await sleepForRetry(delay) }
            retryWait = wait
            try await withTaskCancellationHandler {
                try await wait.value
            } onCancel: {
                wait.cancel()
            }
            try Task.checkCancellation()
            guard session.lifetime == stamp, session.state == .reconnecting else { throw CancellationError() }
            retryWait = nil
            session.state = open(at: session.requestedSize)
            if let event = takePendingEvent() { return event }
        }

        guard let current = socket, session.state != .closing else { throw TransportError.inactiveTransport }
        // An in-band ready and its following binary replay publish one complete generation.
        while true {
            if let event = try await receiveEvent(from: current, in: session, stamp: stamp) { return event }
        }
    }

    private func receiveEvent(from current: URLSessionWebSocketTask, in session: isolated SessionActor,
                              stamp: UInt64) async throws -> SessionActor.Event? {
        let attachment = socketAttempts
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
            frameTrace?.record("observed", attachment: attachment, message: message,
                               stale: session.lifetime != stamp || socket !== current)
        } catch {
            frameTrace?.record("receive-error", attachment: attachment, note: String(describing: error),
                               stale: session.lifetime != stamp || socket !== current, closeCode: current.closeCode.rawValue)
            guard session.lifetime == stamp, session.state != .closing else { throw CancellationError() }
            if socket === current { lost(current, in: session) }
            if let event = takePendingEvent() { return event }
            throw error
        }
        guard session.lifetime == stamp else { throw CancellationError() }
        guard socket === current else {
            if let event = takePendingEvent() { return event }
            throw CancellationError()
        }

        do {
            switch message {
            case .data(let bytes):
                guard session.state == .active || session.state == .awaitingReplay || session.state == .closing else {
                    throw TransportError.unexpectedMessage
                }
                session.recordReceipt(of: bytes)
                frameTrace?.record("accepted", attachment: attachment, message: message, received: session.receivedBytes, applied: session.appliedBytes)
                let replay = nextReplay
                nextReplay = nil
                if let replay {
                    // The last screen stays visible until the complete replay can replace it.
                    let size = replay == .resumed ? attachmentSize : session.terminal.size
                    session.terminal = Terminal(size: size, palette: session.terminal.palette,
                                                cursorColor: session.terminal.cursorColor)
                }
                let reply = session.apply(bytes)
                frameTrace?.record("applied", attachment: attachment, message: message, received: session.receivedBytes, applied: session.appliedBytes)
                onOutput?(bytes)
                await session.publishMetadata(title: session.terminal.title)
                guard session.lifetime == stamp else { throw CancellationError() }
                do {
                    if !reply.isEmpty && session.state != .closing { try await write(.data(Data(reply)), to: current, in: session) }
                    if session.state == .awaitingReplay { try await activate(current, in: session) }
                    if replay == .live && session.state == .active { try await resizeIfNeeded(current, in: session) }
                } catch {
                    // Output was already applied. Present it before reporting its reply's transport failure.
                    guard session.lifetime == stamp, pendingEvent != nil else { throw error }
                }
                guard session.lifetime == stamp else { throw CancellationError() }
                return replay == nil ? .output : .replay

            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, session.state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw TransportError.unexpectedMessage }
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    replacedPreviousShell = session.hasSeenReady && !resumed
                    discardedHeldInputOnLastReady = !resumed && !heldInput.isEmpty
                    session.hasSeenReady = true
                    retryMilliseconds = 250
                    if resumed {
                        nextReplay = .resumed
                        session.state = .awaitingReplay
                    } else {
                        session.terminal = Terminal(size: attachmentSize, palette: session.terminal.palette,
                                                    cursorColor: session.terminal.cursorColor)
                        session.lastReceiptTime = nil
                        discardHeldInput()
                        do { try await activate(current, in: session) }
                        catch { guard session.lifetime == stamp, pendingEvent != nil else { throw error } }
                    }
                    guard session.lifetime == stamp else { throw CancellationError() }
                    // A resumed ready precedes the replay that supplies the authoritative title.
                    await session.publishMetadata(title: resumed ? nil : session.terminal.title, hasEnded: false)
                    guard session.lifetime == stamp else { throw CancellationError() }
                    return .ready(resumed: resumed)
                case (.ready, .active) where control.resumed == true && nextReplay == nil:
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    nextReplay = .live
                    return nil
                case (.exit, .active), (.exit, .closing):
                    frameTrace?.record("exit", attachment: attachment, message: message)
                    if session.state != .closing {
                        park(as: .ended, in: session)
                        session.exitedNaturally = true
                    }
                    let exitLifetime = session.lifetime
                    await session.publishMetadata(hasEnded: true)
                    guard session.lifetime == exitLifetime else { throw CancellationError() }
                    return .exit
                default: throw TransportError.unexpectedMessage
                }
            @unknown default: throw TransportError.unexpectedMessage
            }
        } catch {
            // A malformed server frame fails the protocol. Retrying the same endpoint could
            // otherwise repeat that error forever.
            if socket === current, session.state != .closing { park(as: .idle, in: session) }
            throw error
        }
    }

    private func takePendingEvent() -> SessionActor.Event? {
        defer { pendingEvent = nil }
        return pendingEvent
    }

    func send(_ input: Terminal.Input, in session: isolated SessionActor, notify: (@Sendable () -> Void)?) async throws {
        if recovering {
            let count: Int
            switch input {
            case .text(let text), .paste(let text): count = text.utf8.count
            default:
                // Only typed input can follow a replay to a differently sized screen.
                guard case .key(let key, _) = input else { return }
                if case .character(let character) = key { count = character.utf8.count }
                else { count = 1 }
            }
            guard heldInput.count < 256, count <= 65_536 - heldBytes else { throw TransportError.inputBufferFull }
            heldInput.append(.init(input: input, byteCount: count, onWriteStarted: notify))
            heldBytes += count
            return
        }
        guard let current = socket, session.state == .active else { throw TransportError.inactiveTransport }
        try await send(input, on: current, in: session, notify: notify)
    }

    private func send(_ input: Terminal.Input, on current: URLSessionWebSocketTask, in session: isolated SessionActor,
                      notify: (@Sendable () -> Void)?) async throws {
        let bytes = session.terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current, in: session, onWriteStarted: notify) }
    }

    private func activate(_ current: URLSessionWebSocketTask, in session: isolated SessionActor) async throws {
        // A second loss drops only an attempted write, whose delivery is ambiguous. Later keys
        // still belong to the unsent queue and will use the next resumed shell's input modes.
        while socket === current && session.state != .closing {
            if session.terminal.size != session.requestedSize {
                try await resizeIfNeeded(current, in: session)
            } else if !heldInput.isEmpty {
                let next = heldInput.removeFirst()
                heldBytes -= next.byteCount
                try await send(next.input, on: current, in: session, notify: next.onWriteStarted)
            } else {
                recovering = false
                session.state = .active
                return
            }
        }
        throw CancellationError()
    }

    func resize(in session: isolated SessionActor) async throws {
        guard let current = socket, session.state == .active, nextReplay == nil else { return }
        try await resizeIfNeeded(current, in: session)
    }

    private func resizeIfNeeded(_ current: URLSessionWebSocketTask, in session: isolated SessionActor) async throws {
        guard session.terminal.size != session.requestedSize else { return }
        session.terminal.resize(to: session.requestedSize)
        try await writeControl(.resize(session.requestedSize), to: current, in: session)
    }

    func close(in session: isolated SessionActor) async throws {
        do { try await requestClose(in: session) }
        catch {
            if session.state == .ended { await session.publishMetadata(hasEnded: true) }
            throw error
        }
        await session.publishMetadata(hasEnded: true)
    }

    private func requestClose(in session: isolated SessionActor) async throws {
        session.exitedNaturally = false
        guard session.state != .closing else { throw TransportError.inactiveTransport }
        guard let current = socket else {
            park(as: .ended, in: session)
            throw TransportError.inactiveTransport
        }
        session.state = .closing
        discardHeldInput()
        defer { if socket === current { park(as: .ended, in: session) } }
        try await writeControl(.close, to: current, in: session)
    }

    func detach(from session: isolated SessionActor) {
        frameTrace?.record("detach", attachment: socketAttempts)
        guard session.state != .displaced, session.state != .ended, session.state != .closing else { return }
        park(as: socket?.closeCode.rawValue == 4000 ? .displaced : .idle, in: session)
    }

    private func discardHeldInput() {
        heldInput.removeAll()
        heldBytes = 0
        recovering = false
    }

    private func releaseSocket(in session: isolated SessionActor) {
        nextReplay = nil
        let current = socket
        socket = nil
        session.lastWrite = nil
        if let current {
            frameTrace?.record("cancel", attachment: socketAttempts, closeCode: current.closeCode.rawValue)
            current.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func park(as destination: SessionActor.State, in session: isolated SessionActor) {
        session.lifetime &+= 1
        isReading = false
        retryWait?.cancel()
        retryWait = nil
        retryMilliseconds = 250
        pendingEvent = nil
        discardHeldInput()
        releaseSocket(in: session)
        session.state = destination
    }

    private func beginRecovery(in session: isolated SessionActor) {
        recovering = true
        session.state = .reconnecting
        pendingEvent = .reconnecting
    }

    private func lost(_ current: URLSessionWebSocketTask, in session: isolated SessionActor) {
        let displaced = current.closeCode.rawValue == 4000
        releaseSocket(in: session)
        if displaced {
            discardHeldInput()
            retryMilliseconds = 250
            session.state = .displaced
            pendingEvent = .displaced
        } else {
            beginRecovery(in: session)
        }
    }

    private func writeControl(_ control: ClientControl, to current: URLSessionWebSocketTask,
                              in session: isolated SessionActor) async throws {
        let data = try JSONEncoder().encode(control)
        try await write(.string(String(decoding: data, as: UTF8.self)), to: current, in: session)
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask,
                       in session: isolated SessionActor, onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        let next = session.orderWrite { session in
            guard case .webSocket(let active) = session.transport, active.socket === current else { throw CancellationError() }
            onWriteStarted?()
            if let trace = active.frameTrace, case .string = message {
                trace.record("control-write", attachment: active.socketAttempts, message: message)
            }
            try await current.send(message)
        }
        do {
            try await next.value
            guard socket === current else { throw CancellationError() }
        } catch {
            if socket === current, session.state != .closing { lost(current, in: session) }
            throw error
        }
    }
}

extension SessionActor {
    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any WebSocketFrameTrace)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil) throws {
        let socket = try WebSocketTransport(baseURL: baseURL, clientID: clientID, onOutput: onOutput, frameTrace: frameTrace)
        self.init(socket: socket, size: size, palette: palette, observer: observer)
    }

    package init(size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any WebSocketFrameTrace)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        let socket = WebSocketTransport(onOutput: onOutput, frameTrace: frameTrace,
                                        sleepForRetry: sleepForRetry, makeSocket: makeSocket)
        self.init(socket: socket, size: size, palette: palette, observer: observer)
    }

    private init(socket: WebSocketTransport, size: Terminal.Size?, palette: Terminal.Palette,
                 observer: TerminalSession.MetadataObserver?) {
        let state = size.map { socket.open(at: $0) } ?? .idle
        self.init(transport: .webSocket(socket), size: size, palette: palette, state: state, observer: observer)
    }

    private var webSocket: WebSocketTransport? {
        if case .webSocket(let socket) = transport { return socket }
        return nil
    }

    /// Includes failed opens and retries.
    package var socketAttempts: Int { webSocket?.socketAttempts ?? 0 }
    package var awaitingReplay: Bool { webSocket?.awaitingReplay ?? false }
    /// A fresh shell after any previous ready, except for a user-initiated restart after exit.
    package var replacedPreviousShell: Bool { webSocket?.replacedPreviousShell ?? false }
    package var discardedHeldInputOnLastReady: Bool { webSocket?.discardedHeldInputOnLastReady ?? false }

    package func finishFrameTrace(_ result: String) async {
        guard let socket = webSocket else { return }
        await socket.frameTrace?.finish(result, attachment: socket.socketAttempts, received: receivedBytes, applied: appliedBytes)
    }
}
