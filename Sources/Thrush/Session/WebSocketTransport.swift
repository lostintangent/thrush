import Foundation
import ThrushCore

/// Manages a session's WebSocket attachments on its session actor.
final class WebSocketTransport: SessionActor.Transport {
    private typealias TransportError = SessionActor.TransportError

    private struct ServerControl: Decodable {
        enum Kind: String, Decodable { case ready, resize, exit }
        let type: Kind
        let resumed: Bool?
        let answersResize: Bool?
        let cols: Int?
        let rows: Int?
    }

    private struct ClientControl: Encodable, Sendable {
        private enum Kind: String, Encodable { case resize, close }
        private let type: Kind
        private let cols: Int?
        private let rows: Int?
        private let answer: Bool?

        static func resize(_ size: Terminal.Size, answered: Bool) -> Self {
            Self(type: .resize, cols: size.columns, rows: size.rows, answer: answered ? true : nil)
        }

        static let close = Self(type: .close, cols: nil, rows: nil, answer: nil)
    }

    private struct HeldInput {
        let input: Terminal.Input
        let byteCount: Int
    }

    private let createTask: @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask
    fileprivate var frameTrace: (any WebSocketFrameTrace)?
    private let sleepForRetry: @Sendable (Duration) async throws -> Void
    private var socket: URLSessionWebSocketTask?
    /// The grid this attachment last gave the server, starting with the one in its URL.
    private var sentSize = Terminal.Size(columns: 80, rows: 24)
    /// The server answers each resize at the point in its output where its terminal took the grid.
    private var answersResize = false
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

    init(sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.createTask = makeSocket
        self.sleepForRetry = sleepForRetry
    }

    deinit {
        retryWait?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    fileprivate func open(at size: Terminal.Size) -> SessionActor.State {
        socketAttempts += 1
        do {
            let next = try createTask(size)
            // A replay of a thousand rows of styled history can exceed URLSession's 1 MiB default.
            next.maximumMessageSize = max(next.maximumMessageSize, 64 * 1024 * 1024)
            socket = next
            sentSize = size
            frameTrace?.record("open", attachment: socketAttempts)
            next.resume()
            return .connecting
        } catch {
            recovering = true
            pendingEvent = .reconnecting
            return .reconnecting
        }
    }

    func show(userInitiated: Bool, in session: isolated SessionActor) -> Bool {
        guard session.beginOpening(userInitiated: userInitiated) else { return false }
        pendingEvent = nil
        isReading = false
        recovering = session.hasSeenReady
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
        try session.checkLifetime(stamp)
        guard socket === current else {
            if let event = takePendingEvent() { return event }
            throw CancellationError()
        }

        do {
            switch message {
            case .data(let bytes):
                guard session.state == .live || session.state == .awaitingReplay || session.state == .closing else {
                    throw TransportError.unexpectedMessage
                }
                session.recordReceipt(of: bytes)
                frameTrace?.record("accepted", attachment: attachment, message: message, received: session.receivedBytes)
                let replay = nextReplay
                nextReplay = nil
                if let replay {
                    // The last screen stays visible until the complete replay can replace it.
                    let size = replay == .resumed ? sentSize : session.terminal.size
                    session.terminal.prepareForReplay(at: size)
                }
                let reply = session.apply(bytes)
                // The reply reports the focus of this moment, so it's queued before anything can suspend
                // and let a later focus report overtake it.
                let replyFocus = session.terminal.isFocused
                frameTrace?.record("applied", attachment: attachment, message: message, received: session.receivedBytes)
                do {
                    if !reply.isEmpty && session.state != .closing { try await write(.data(Data(reply)), to: current, in: session) }
                    if session.state == .awaitingReplay { try await activate(current, replyFocus: replyFocus, in: session) }
                    if replay == .live && session.state == .live { try await resizeIfNeeded(current, in: session) }
                } catch {
                    // Output was already applied. Present it before reporting its reply's transport failure.
                    guard session.lifetime == stamp, pendingEvent != nil else { throw error }
                }
                try session.checkLifetime(stamp)
                await session.publishMetadata()
                try session.checkLifetime(stamp)
                return replay == nil ? .output : .replay

            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, session.state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw TransportError.unexpectedMessage }
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    let replaced = session.hasSeenReady && !resumed
                    session.hasSeenReady = true
                    answersResize = control.answersResize == true
                    retryMilliseconds = 250
                    if resumed {
                        nextReplay = .resumed
                        session.state = .awaitingReplay
                    } else {
                        if replaced {
                            session.shellRevision &+= 1
                            session.terminal.startNewShell(at: sentSize)
                        } else {
                            session.resetTerminal(size: sentSize)
                        }
                        session.lastReceiptTime = nil
                        discardHeldInput()
                        do { try await activate(current, in: session) }
                        catch { guard session.lifetime == stamp, pendingEvent != nil else { throw error } }
                    }
                    try session.checkLifetime(stamp)
                    await session.publishMetadata()
                    try session.checkLifetime(stamp)
                    return replaced ? .replaced : .ready(resumed: resumed)
                case (.ready, .live) where control.resumed == true && nextReplay == nil:
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    nextReplay = .live
                    return nil
                case (.resize, .live), (.resize, .closing):
                    guard answersResize, let columns = control.cols, let rows = control.rows, columns > 0, rows > 0 else {
                        throw TransportError.unexpectedMessage
                    }
                    frameTrace?.record("resize", attachment: attachment, message: message)
                    session.terminal.resize(to: .init(columns: columns, rows: rows))
                    return .output
                case (.exit, .live), (.exit, .closing):
                    frameTrace?.record("exit", attachment: attachment, message: message)
                    if session.state != .closing {
                        park(as: .ended, in: session)
                    }
                    let exitLifetime = session.lifetime
                    await session.publishMetadata(ended: true)
                    try session.checkLifetime(exitLifetime)
                    return .ended
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

    func send(_ input: Terminal.Input, in session: isolated SessionActor) async throws {
        if recovering {
            let count: Int
            switch input {
            case .text(let text), .paste(let text): count = text.utf8.count
            default:
                // Only typed input can follow a replay to a differently sized screen. Focus isn't held
                // because the replay's reply and activation report the current focus.
                guard case .key(let key, _) = input else { return }
                if case .character(let character) = key { count = character.utf8.count }
                else { count = 1 }
            }
            guard heldInput.count < 256, count <= 65_536 - heldBytes else { throw TransportError.inputBufferFull }
            heldInput.append(.init(input: input, byteCount: count))
            heldBytes += count
            return
        }
        guard let current = socket, session.state == .live else { throw TransportError.inactiveTransport }
        try await send(input, on: current, in: session)
    }

    private func send(_ input: Terminal.Input, on current: URLSessionWebSocketTask, in session: isolated SessionActor) async throws {
        let bytes = session.terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current, in: session, tracedAs: "input-write") }
    }

    /// Writes held input once the shell is current. A replayed program that reports focus first hears
    /// any change since its reply reported `replyFocus`, because focus changes aren't held. One that
    /// reports appearance hears the current one, because another attachment may have told it otherwise.
    private func activate(_ current: URLSessionWebSocketTask, replyFocus: Bool? = nil,
                          in session: isolated SessionActor) async throws {
        // A second loss drops only an attempted write, whose delivery is ambiguous. Later keys
        // still belong to the unsent queue and will use the next resumed shell's input modes.
        var heardFocus = replyFocus
        var heardAppearance: Terminal.Appearance?
        while socket === current && session.state != .closing {
            let focus = session.terminal.isFocused
            let appearance = session.terminal.appearance
            if sentSize != session.requestedSize {
                try await resizeIfNeeded(current, in: session)
            } else if session.terminal.modes.sendFocus, let heard = heardFocus, heard != focus {
                heardFocus = focus
                try await send(.focus(focus), on: current, in: session)
            } else if session.terminal.modes.reportAppearance, let appearance, appearance != heardAppearance {
                heardAppearance = appearance
                try await send(.appearance(appearance), on: current, in: session)
            } else if !heldInput.isEmpty {
                let next = heldInput.removeFirst()
                heldBytes -= next.byteCount
                try await send(next.input, on: current, in: session)
            } else {
                recovering = false
                session.state = .live
                return
            }
        }
        throw CancellationError()
    }

    func resize(in session: isolated SessionActor) async throws {
        guard let current = socket, session.state == .live, nextReplay == nil else { return }
        try await resizeIfNeeded(current, in: session)
    }

    /// A server that answers resizes the terminal at its answer, so every byte meets the grid the server
    /// parsed it at. Otherwise the terminal takes the grid at once.
    private func resizeIfNeeded(_ current: URLSessionWebSocketTask, in session: isolated SessionActor) async throws {
        let size = session.requestedSize
        guard size != sentSize else { return }
        sentSize = size
        if !answersResize { session.terminal.resize(to: size) }
        try await writeControl(.resize(size, answered: answersResize), to: current, in: session)
    }

    func close(in session: isolated SessionActor) async throws {
        do { try await requestClose(in: session) }
        catch {
            if session.state == .ended { await session.publishMetadata(ended: true) }
            throw error
        }
        await session.publishMetadata(ended: true)
    }

    private func requestClose(in session: isolated SessionActor) async throws {
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

    /// Ends the attachment. The server keeps the shell for the next one.
    func hide(in session: isolated SessionActor) {
        frameTrace?.record("detach", attachment: socketAttempts)
        guard session.state != .displaced, session.state != .ended, session.state != .closing else { return }
        park(as: socket?.closeCode.rawValue == 4000 ? .displaced : .idle, in: session)
    }

    func release(in session: isolated SessionActor) async { hide(in: session) }

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
        try await write(.string(String(decoding: data, as: UTF8.self)), to: current, in: session, tracedAs: "control-write")
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began. A trace hears each input and control
    /// write as it begins, including one whose delivery a socket loss leaves ambiguous.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask,
                       in session: isolated SessionActor, tracedAs event: String? = nil) async throws {
        let next = session.orderWrite { session in
            guard let active = session.webSocket, active.socket === current else { throw CancellationError() }
            if let event { active.frameTrace?.record(event, attachment: active.socketAttempts, message: message) }
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
    package init(size: Terminal.Size?, palette: Terminal.Palette = .default,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        let socket = WebSocketTransport(sleepForRetry: sleepForRetry, makeSocket: makeSocket)
        self.init(socket: socket, size: size, palette: palette, observer: nil)
    }

    init(observer: TerminalSession.MetadataObserver, makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init(socket: WebSocketTransport(makeSocket: makeSocket), size: nil, palette: .default, observer: observer)
    }

    private init(socket: WebSocketTransport, size: Terminal.Size?, palette: Terminal.Palette,
                 observer: TerminalSession.MetadataObserver?) {
        let state = size.map { socket.open(at: $0) } ?? .idle
        self.init(transport: socket, size: size, palette: palette, state: state, observer: observer)
    }

    fileprivate var webSocket: WebSocketTransport? { transport as? WebSocketTransport }

    /// Includes failed opens and retries.
    package var socketAttempts: Int { webSocket?.socketAttempts ?? 0 }
    package var awaitingReplay: Bool { webSocket?.awaitingReplay ?? false }

    /// Observes this session's WebSocket from its next event. Install a trace before showing an
    /// idle session to see its first attachment open.
    package func trace(with trace: (any WebSocketFrameTrace)?) { webSocket?.frameTrace = trace }
}
