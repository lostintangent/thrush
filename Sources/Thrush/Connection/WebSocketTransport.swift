import Foundation
import ThrushCore

/// Manages a session's WebSocket attachments on its worker actor.
final class WebSocketTransport {
    private typealias ConnectionError = TerminalWorker.ConnectionError

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
    fileprivate let frameTrace: (any ConnectionFrameObserver)?
    private let sleepForRetry: @Sendable (Duration) async throws -> Void
    private var socket: URLSessionWebSocketTask?
    private var attachmentSize = Terminal.Size(columns: 80, rows: 24)
    private var retryWait: Task<Void, Error>?
    private var retryMilliseconds = 250
    private var pendingEvent: TerminalWorker.Event?
    private var recovering = false
    private var isReading = false
    private var heldInput: [HeldInput] = []
    private var heldBytes = 0

    fileprivate var socketAttempts = 0
    fileprivate var isResynchronizing = false
    fileprivate var replacedPreviousShell = false
    fileprivate var discardedHeldInputOnLastReady = false

    init(onOutput: (@Sendable (Data) -> Void)?, frameTrace: (any ConnectionFrameObserver)?,
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

    /// Only the convenience endpoint owns a URLSession. A host-supplied factory keeps its own.
    private final class DemoSession: Sendable {
        let session = URLSession(configuration: .ephemeral)
        deinit { session.invalidateAndCancel() }
    }

    convenience init(baseURL: URL, clientID: String, onOutput: (@Sendable (Data) -> Void)?,
                     frameTrace: (any ConnectionFrameObserver)?) throws {
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
            // A single repaint can include a thousand rows of colored scrollback.
            task.maximumMessageSize = 64 * 1024 * 1024
            return task
        }
    }

    fileprivate func open(at size: Terminal.Size) -> TerminalWorker.State {
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

    func attach(to worker: isolated TerminalWorker, userInitiated: Bool) -> Bool {
        guard worker.beginAttachment(userInitiated: userInitiated) else { return false }
        pendingEvent = nil
        isReading = false
        worker.state = open(at: worker.requestedSize)
        return true
    }

    func nextEvent(in worker: isolated TerminalWorker) async throws -> TerminalWorker.Event {
        guard !isReading else { throw ConnectionError.concurrentRead }
        isReading = true
        let stamp = worker.lifetime
        defer { if worker.lifetime == stamp { isReading = false } }

        if let event = takePendingEvent() { return event }
        if worker.state == .reconnecting {
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
            guard worker.lifetime == stamp, worker.state == .reconnecting else { throw CancellationError() }
            retryWait = nil
            worker.state = open(at: worker.requestedSize)
            if let event = takePendingEvent() { return event }
        }

        guard let current = socket, worker.state != .closing else { throw ConnectionError.inactiveAttachment }
        // An in-band ready and its following binary replay publish one complete generation.
        while true {
            if let event = try await receiveEvent(from: current, in: worker, stamp: stamp) { return event }
        }
    }

    private func receiveEvent(from current: URLSessionWebSocketTask, in worker: isolated TerminalWorker,
                              stamp: UInt64) async throws -> TerminalWorker.Event? {
        let attachment = socketAttempts
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
            frameTrace?.record("observed", attachment: attachment, message: message,
                               stale: worker.lifetime != stamp || socket !== current)
        } catch {
            frameTrace?.record("receive-error", attachment: attachment, note: String(describing: error),
                               stale: worker.lifetime != stamp || socket !== current, closeCode: current.closeCode.rawValue)
            guard worker.lifetime == stamp, worker.state != .closing else { throw CancellationError() }
            if socket === current { lost(current, in: worker) }
            if let event = takePendingEvent() { return event }
            throw error
        }
        guard worker.lifetime == stamp else { throw CancellationError() }
        guard socket === current else {
            if let event = takePendingEvent() { return event }
            throw CancellationError()
        }

        do {
            switch message {
            case .data(let bytes):
                guard worker.state == .active || worker.state == .replaying || worker.state == .closing else {
                    throw ConnectionError.unexpectedMessage
                }
                worker.recordReceipt(of: bytes)
                frameTrace?.record("accepted", attachment: attachment, message: message, received: worker.receivedBytes, applied: worker.appliedBytes)
                let resynchronized = isResynchronizing
                if resynchronized {
                    // No actor suspension between resetting the parser and applying the checkpoint.
                    // The old grid kept its negotiated size while the new checkpoint was in flight.
                    worker.terminal = Terminal(size: worker.terminal.size, palette: worker.terminal.palette)
                    isResynchronizing = false
                }
                let reply = worker.apply(bytes)
                frameTrace?.record("applied", attachment: attachment, message: message, received: worker.receivedBytes, applied: worker.appliedBytes)
                onOutput?(bytes)
                await worker.publishMetadata(title: worker.terminal.title)
                guard worker.lifetime == stamp else { throw CancellationError() }
                do {
                    if !reply.isEmpty && worker.state != .closing { try await write(.data(Data(reply)), to: current, in: worker) }
                    if worker.state == .replaying { try await activate(current, in: worker) }
                    if resynchronized && worker.state == .active { try await resizeIfNeeded(current, in: worker) }
                } catch {
                    // Output was already applied. Present it before reporting its reply's transport failure.
                    guard worker.lifetime == stamp, pendingEvent != nil else { throw error }
                }
                guard worker.lifetime == stamp else { throw CancellationError() }
                return resynchronized ? .resynchronized : .output

            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, worker.state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    replacedPreviousShell = worker.hasSeenReady && !resumed
                    discardedHeldInputOnLastReady = !resumed && !heldInput.isEmpty
                    worker.hasSeenReady = true
                    retryMilliseconds = 250
                    worker.terminal = Terminal(size: attachmentSize, palette: worker.terminal.palette)
                    worker.lastReceiptTime = nil
                    if resumed {
                        worker.state = .replaying
                    } else {
                        discardHeldInput()
                        do { try await activate(current, in: worker) }
                        catch { guard worker.lifetime == stamp, pendingEvent != nil else { throw error } }
                    }
                    guard worker.lifetime == stamp else { throw CancellationError() }
                    // A resumed ready precedes the replay that supplies the authoritative title.
                    await worker.publishMetadata(title: resumed ? nil : worker.terminal.title, hasEnded: false)
                    guard worker.lifetime == stamp else { throw CancellationError() }
                    return .ready(resumed: resumed)
                case (.ready, .active) where control.resumed == true && !isResynchronizing:
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    isResynchronizing = true
                    return nil
                case (.exit, .active), (.exit, .closing):
                    frameTrace?.record("exit", attachment: attachment, message: message)
                    if worker.state != .closing {
                        park(as: .ended, in: worker)
                        worker.exitedNaturally = true
                    }
                    let exitLifetime = worker.lifetime
                    await worker.publishMetadata(hasEnded: true)
                    guard worker.lifetime == exitLifetime else { throw CancellationError() }
                    return .exit
                default: throw ConnectionError.unexpectedMessage
                }
            @unknown default: throw ConnectionError.unexpectedMessage
            }
        } catch {
            // A malformed server frame fails the protocol. Retrying the same endpoint could
            // otherwise repeat that error forever.
            if socket === current, worker.state != .closing { park(as: .detached, in: worker) }
            throw error
        }
    }

    private func takePendingEvent() -> TerminalWorker.Event? {
        defer { pendingEvent = nil }
        return pendingEvent
    }

    func send(_ input: Terminal.Input, in worker: isolated TerminalWorker, notify: (@Sendable () -> Void)?) async throws {
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
            guard heldInput.count < 256, count <= 65_536 - heldBytes else { throw ConnectionError.inputBufferFull }
            heldInput.append(.init(input: input, byteCount: count, onWriteStarted: notify))
            heldBytes += count
            return
        }
        guard let current = socket, worker.state == .active else { throw ConnectionError.inactiveAttachment }
        try await send(input, on: current, in: worker, notify: notify)
    }

    private func send(_ input: Terminal.Input, on current: URLSessionWebSocketTask, in worker: isolated TerminalWorker,
                      notify: (@Sendable () -> Void)?) async throws {
        let bytes = worker.terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current, in: worker, onWriteStarted: notify) }
    }

    private func activate(_ current: URLSessionWebSocketTask, in worker: isolated TerminalWorker) async throws {
        // A second loss drops only an attempted write, whose delivery is ambiguous. Later keys
        // still belong to the unsent queue and will use the next resumed shell's input modes.
        while socket === current && worker.state != .closing {
            if worker.terminal.size != worker.requestedSize {
                try await resizeIfNeeded(current, in: worker)
            } else if !heldInput.isEmpty {
                let next = heldInput.removeFirst()
                heldBytes -= next.byteCount
                try await send(next.input, on: current, in: worker, notify: next.onWriteStarted)
            } else {
                recovering = false
                worker.state = .active
                return
            }
        }
        throw CancellationError()
    }

    func resize(in worker: isolated TerminalWorker) async throws {
        guard let current = socket, worker.state == .active, !isResynchronizing else { return }
        try await resizeIfNeeded(current, in: worker)
    }

    private func resizeIfNeeded(_ current: URLSessionWebSocketTask, in worker: isolated TerminalWorker) async throws {
        guard worker.terminal.size != worker.requestedSize else { return }
        worker.terminal.resize(to: worker.requestedSize)
        try await writeControl(.resize(worker.requestedSize), to: current, in: worker)
    }

    func close(in worker: isolated TerminalWorker) async throws {
        do { try await requestClose(in: worker) }
        catch {
            if worker.state == .ended { await worker.publishMetadata(hasEnded: true) }
            throw error
        }
        await worker.publishMetadata(hasEnded: true)
    }

    private func requestClose(in worker: isolated TerminalWorker) async throws {
        worker.exitedNaturally = false
        guard worker.state != .closing else { throw ConnectionError.inactiveAttachment }
        guard let current = socket else {
            park(as: .ended, in: worker)
            throw ConnectionError.inactiveAttachment
        }
        worker.state = .closing
        discardHeldInput()
        defer { if socket === current { park(as: .ended, in: worker) } }
        try await writeControl(.close, to: current, in: worker)
    }

    func detach(from worker: isolated TerminalWorker) {
        frameTrace?.record("detach", attachment: socketAttempts)
        guard worker.state != .displaced, worker.state != .ended, worker.state != .closing else { return }
        park(as: socket?.closeCode.rawValue == 4000 ? .displaced : .detached, in: worker)
    }

    private func discardHeldInput() {
        heldInput.removeAll()
        heldBytes = 0
        recovering = false
    }

    private func releaseSocket(in worker: isolated TerminalWorker) {
        isResynchronizing = false
        let current = socket
        socket = nil
        worker.lastWrite = nil
        if let current {
            frameTrace?.record("cancel", attachment: socketAttempts, closeCode: current.closeCode.rawValue)
            current.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func park(as destination: TerminalWorker.State, in worker: isolated TerminalWorker) {
        worker.lifetime &+= 1
        isReading = false
        retryWait?.cancel()
        retryWait = nil
        retryMilliseconds = 250
        pendingEvent = nil
        discardHeldInput()
        releaseSocket(in: worker)
        worker.state = destination
    }

    private func beginRecovery(in worker: isolated TerminalWorker) {
        recovering = true
        worker.state = .reconnecting
        pendingEvent = .reconnecting
    }

    private func lost(_ current: URLSessionWebSocketTask, in worker: isolated TerminalWorker) {
        let displaced = current.closeCode.rawValue == 4000
        releaseSocket(in: worker)
        if displaced {
            discardHeldInput()
            retryMilliseconds = 250
            worker.state = .displaced
            pendingEvent = .displaced
        } else {
            beginRecovery(in: worker)
        }
    }

    private func writeControl(_ control: ClientControl, to current: URLSessionWebSocketTask,
                              in worker: isolated TerminalWorker) async throws {
        let data = try JSONEncoder().encode(control)
        try await write(.string(String(decoding: data, as: UTF8.self)), to: current, in: worker)
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask,
                       in worker: isolated TerminalWorker, onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        let next = worker.orderWrite { worker in
            guard case .webSocket(let active) = worker.transport, active.socket === current else { throw CancellationError() }
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
            if socket === current, worker.state != .closing { lost(current, in: worker) }
            throw error
        }
    }
}

extension TerminalWorker {
    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil) throws {
        let socket = try WebSocketTransport(baseURL: baseURL, clientID: clientID, onOutput: onOutput, frameTrace: frameTrace)
        self.init(socket: socket, size: size, palette: palette, observer: observer)
    }

    package init(size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        let socket = WebSocketTransport(onOutput: onOutput, frameTrace: frameTrace,
                                        sleepForRetry: sleepForRetry, makeSocket: makeSocket)
        self.init(socket: socket, size: size, palette: palette, observer: observer)
    }

    private init(socket: WebSocketTransport, size: Terminal.Size?, palette: Terminal.Palette,
                 observer: TerminalSession.MetadataObserver?) {
        let state = size.map { socket.open(at: $0) } ?? .detached
        self.init(transport: .webSocket(socket), size: size, palette: palette, state: state, observer: observer)
    }

    private var webSocket: WebSocketTransport? {
        if case .webSocket(let socket) = transport { return socket }
        return nil
    }

    /// Includes failed opens and retries.
    package var socketAttempts: Int { webSocket?.socketAttempts ?? 0 }
    package var isResynchronizing: Bool { webSocket?.isResynchronizing ?? false }
    /// A fresh shell after any previous ready, except for a user-initiated restart after exit.
    package var replacedPreviousShell: Bool { webSocket?.replacedPreviousShell ?? false }
    package var discardedHeldInputOnLastReady: Bool { webSocket?.discardedHeldInputOnLastReady ?? false }

    package func finishFrameTrace(_ result: String) async {
        guard let socket = webSocket else { return }
        await socket.frameTrace?.finish(result, attachment: socket.socketAttempts, received: receivedBytes, applied: appliedBytes)
    }
}
