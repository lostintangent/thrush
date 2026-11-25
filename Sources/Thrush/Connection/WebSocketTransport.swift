import Foundation
import QuartzCore
import ThrushCore

/// Opens suspended tasks and translates Thrush's WebSocket control messages.
struct WebSocketTransport: Sendable {
    struct ServerControl: Decodable {
        enum Kind: String, Decodable { case ready, exit }
        let type: Kind
        let resumed: Bool?
    }

    struct ClientControl: Encodable, Sendable {
        private enum Kind: String, Encodable { case resize, close }
        private let type: Kind
        private let cols: Int?
        private let rows: Int?

        static func resize(_ size: Terminal.Size) -> Self {
            Self(type: .resize, cols: size.columns, rows: size.rows)
        }

        static let close = Self(type: .close, cols: nil, rows: nil)
    }

    private let createTask: @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask

    init(makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        createTask = makeSocket
    }

    /// Only the convenience endpoint owns a URLSession. A host-supplied factory keeps its own.
    private final class DemoSession: Sendable {
        let session = URLSession(configuration: .ephemeral)
        deinit { session.invalidateAndCancel() }
    }

    init(baseURL: URL, clientID: String) throws {
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
        self.init { size in
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

    func makeSocket(size: Terminal.Size) throws -> URLSessionWebSocketTask {
        try createTask(size)
    }

    static func decode(_ text: String) throws -> ServerControl {
        try JSONDecoder().decode(ServerControl.self, from: Data(text.utf8))
    }

    static func encode(_ control: ClientControl) throws -> URLSessionWebSocketTask.Message {
        let bytes = try JSONEncoder().encode(control)
        return .string(String(decoding: bytes, as: UTF8.self))
    }
}

/// State for the socket attached to this worker, isolated by the worker actor.
struct WebSocketAttachment {
    struct HeldInput {
        let input: Terminal.Input
        let byteCount: Int
        let onWriteStarted: (@Sendable () -> Void)?
    }

    var socket: URLSessionWebSocketTask?
    var attachmentSize: Terminal.Size
    var retryWait: Task<Void, Error>?
    var retryMilliseconds = 250
    var pendingEvent: TerminalWorker.Event?
    var recovering = false
    var isReading = false
    var heldInput: [HeldInput] = []
    var heldBytes = 0
}

extension TerminalWorker {
    func openSocket() {
        guard case .webSocket(let webSocket) = transport else { return }
        socketAttempts += 1
        do {
            let next = try webSocket.makeSocket(size: requestedSize)
            wire.attachmentSize = requestedSize
            wire.socket = next
            state = .connecting
            frameTrace?.record("open", attachment: socketAttempts)
            next.resume()
        } catch {
            beginRecovery()
        }
    }

    func nextSocketEvent() async throws -> Event {
        guard !wire.isReading else { throw ConnectionError.concurrentRead }
        wire.isReading = true
        let stamp = lifetime
        defer { if lifetime == stamp { wire.isReading = false } }

        if let event = takePendingEvent() { return event }
        if state == .reconnecting {
            let delay = Duration.milliseconds(wire.retryMilliseconds)
            wire.retryMilliseconds = min(wire.retryMilliseconds * 2, 4_000)
            let wait = Task { [sleepForRetry] in try await sleepForRetry(delay) }
            wire.retryWait = wait
            try await withTaskCancellationHandler {
                try await wait.value
            } onCancel: {
                wait.cancel()
            }
            try Task.checkCancellation()
            guard lifetime == stamp, state == .reconnecting else { throw CancellationError() }
            wire.retryWait = nil
            openSocket()
            if let event = takePendingEvent() { return event }
        }

        guard let current = wire.socket, state != .closing else { throw ConnectionError.inactiveAttachment }
        // An in-band ready and its following binary replay publish one complete generation.
        while true {
            if let event = try await receiveEvent(from: current, lifetime: stamp) { return event }
        }
    }

    private func receiveEvent(from current: URLSessionWebSocketTask, lifetime stamp: UInt64) async throws -> Event? {
        let attachment = socketAttempts
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
            frameTrace?.record("observed", attachment: attachment, message: message,
                               stale: lifetime != stamp || wire.socket !== current)
        } catch {
            frameTrace?.record("receive-error", attachment: attachment, note: String(describing: error),
                               stale: lifetime != stamp || wire.socket !== current, closeCode: current.closeCode.rawValue)
            guard lifetime == stamp, state != .closing else { throw CancellationError() }
            if wire.socket === current { lost(current) }
            if let event = takePendingEvent() { return event }
            throw error
        }
        guard lifetime == stamp else { throw CancellationError() }
        guard wire.socket === current else {
            if let event = takePendingEvent() { return event }
            throw CancellationError()
        }

        do {
            switch message {
            case .data(let bytes):
                guard state == .active || state == .replaying || state == .closing else {
                    throw ConnectionError.unexpectedMessage
                }
                lastReceiptTime = CACurrentMediaTime()
                receivedBytes += bytes.count
                frameTrace?.record("accepted", attachment: attachment, message: message, received: receivedBytes, applied: appliedBytes)
                let resynchronized = isResynchronizing
                if resynchronized {
                    // No actor suspension between resetting the parser and applying the checkpoint.
                    // The old grid kept its negotiated size while the new checkpoint was in flight.
                    terminal = Terminal(size: terminal.size, palette: terminal.palette)
                    isResynchronizing = false
                }
                let reply = terminal.receive(Span(viewing: bytes.bytes))
                appliedBytes += bytes.count
                frameTrace?.record("applied", attachment: attachment, message: message, received: receivedBytes, applied: appliedBytes)
                onOutput?(bytes)
                await publishMetadata(title: terminal.title)
                guard lifetime == stamp else { throw CancellationError() }
                do {
                    if !reply.isEmpty && state != .closing { try await write(.data(Data(reply)), to: current) }
                    if state == .replaying { try await activate(current) }
                    if resynchronized && state == .active { try await resizeIfNeeded(current) }
                } catch {
                    // Output was already applied. Present it before reporting its reply's transport failure.
                    guard lifetime == stamp, wire.pendingEvent != nil else { throw error }
                }
                guard lifetime == stamp else { throw CancellationError() }
                return resynchronized ? .resynchronized : .output

            case .string(let json):
                let control = try WebSocketTransport.decode(json)
                switch (control.type, state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    replacedPreviousShell = hasSeenReady && !resumed
                    discardedHeldInputOnLastReady = !resumed && !wire.heldInput.isEmpty
                    hasSeenReady = true
                    wire.retryMilliseconds = 250
                    terminal = Terminal(size: wire.attachmentSize, palette: terminal.palette)
                    lastReceiptTime = nil
                    if resumed {
                        state = .replaying
                    } else {
                        discardHeldInput()
                        do { try await activate(current) }
                        catch { guard lifetime == stamp, wire.pendingEvent != nil else { throw error } }
                    }
                    guard lifetime == stamp else { throw CancellationError() }
                    // A resumed ready precedes the replay that supplies the authoritative title.
                    await publishMetadata(title: resumed ? nil : terminal.title, hasEnded: false)
                    guard lifetime == stamp else { throw CancellationError() }
                    return .ready(resumed: resumed)
                case (.ready, .active) where control.resumed == true && !isResynchronizing:
                    frameTrace?.record("ready", attachment: attachment, message: message)
                    isResynchronizing = true
                    return nil
                case (.exit, .active), (.exit, .closing):
                    frameTrace?.record("exit", attachment: attachment, message: message)
                    if state != .closing {
                        park(as: .ended)
                        exitedNaturally = true
                    }
                    let exitLifetime = lifetime
                    await publishMetadata(hasEnded: true)
                    guard lifetime == exitLifetime else { throw CancellationError() }
                    return .exit
                default: throw ConnectionError.unexpectedMessage
                }
            @unknown default: throw ConnectionError.unexpectedMessage
            }
        } catch {
            // A malformed server frame fails the protocol. Retrying the same endpoint could
            // otherwise repeat that error forever.
            if wire.socket === current, state != .closing { park(as: .detached) }
            throw error
        }
    }

    private func takePendingEvent() -> Event? {
        defer { wire.pendingEvent = nil }
        return wire.pendingEvent
    }

    func sendSocketInput(_ input: Terminal.Input, notify: (@Sendable () -> Void)?) async throws {
        if wire.recovering {
            let count: Int
            switch input {
            case .text(let text), .paste(let text): count = text.utf8.count
            default:
                // Only typed input can follow a replay to a differently sized screen.
                guard case .key(let key, _) = input else { return }
                if case .character(let character) = key { count = character.utf8.count }
                else { count = 1 }
            }
            guard wire.heldInput.count < 256, count <= 65_536 - wire.heldBytes else { throw ConnectionError.inputBufferFull }
            wire.heldInput.append(.init(input: input, byteCount: count, onWriteStarted: notify))
            wire.heldBytes += count
            return
        }
        guard let current = wire.socket, state == .active else { throw ConnectionError.inactiveAttachment }
        try await send(input, on: current, notify: notify)
    }

    private func send(_ input: Terminal.Input, on current: URLSessionWebSocketTask,
                      notify: (@Sendable () -> Void)?) async throws {
        let bytes = terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current, onWriteStarted: notify) }
    }

    private func activate(_ current: URLSessionWebSocketTask) async throws {
        // A second loss drops only an attempted write, whose delivery is ambiguous. Later keys
        // still belong to the unsent queue and will use the next resumed shell's input modes.
        while wire.socket === current && state != .closing {
            if terminal.size != requestedSize {
                try await resizeIfNeeded(current)
            } else if !wire.heldInput.isEmpty {
                let next = wire.heldInput.removeFirst()
                wire.heldBytes -= next.byteCount
                try await send(next.input, on: current, notify: next.onWriteStarted)
            } else {
                wire.recovering = false
                state = .active
                return
            }
        }
        throw CancellationError()
    }

    func resizeIfNeeded(_ current: URLSessionWebSocketTask) async throws {
        guard terminal.size != requestedSize else { return }
        terminal.resize(to: requestedSize)
        try await writeControl(.resize(requestedSize), to: current)
    }

    func requestClose() async throws {
        exitedNaturally = false
        guard state != .closing else { throw ConnectionError.inactiveAttachment }
        guard let current = wire.socket else {
            park(as: .ended)
            throw ConnectionError.inactiveAttachment
        }
        state = .closing
        discardHeldInput()
        defer { if wire.socket === current { park(as: .ended) } }
        try await writeControl(.close, to: current)
    }

    func detachSocket() {
        frameTrace?.record("detach", attachment: socketAttempts)
        guard state != .displaced, state != .ended, state != .closing else { return }
        park(as: wire.socket?.closeCode.rawValue == 4000 ? .displaced : .detached)
    }

    private func discardHeldInput() {
        wire.heldInput.removeAll()
        wire.heldBytes = 0
        wire.recovering = false
    }

    private func releaseSocket() {
        isResynchronizing = false
        let current = wire.socket
        wire.socket = nil
        lastWrite = nil
        if let current {
            frameTrace?.record("cancel", attachment: socketAttempts, closeCode: current.closeCode.rawValue)
            current.cancel(with: .normalClosure, reason: nil)
        }
    }

    private func park(as state: State) {
        lifetime &+= 1
        wire.isReading = false
        wire.retryWait?.cancel()
        wire.retryWait = nil
        wire.retryMilliseconds = 250
        wire.pendingEvent = nil
        discardHeldInput()
        releaseSocket()
        self.state = state
    }

    private func beginRecovery() {
        wire.recovering = true
        state = .reconnecting
        wire.pendingEvent = .reconnecting
    }

    private func lost(_ current: URLSessionWebSocketTask) {
        let displaced = current.closeCode.rawValue == 4000
        releaseSocket()
        if displaced {
            discardHeldInput()
            wire.retryMilliseconds = 250
            state = .displaced
            wire.pendingEvent = .displaced
        } else {
            beginRecovery()
        }
    }

    private func writeControl(_ control: WebSocketTransport.ClientControl, to current: URLSessionWebSocketTask) async throws {
        try await write(WebSocketTransport.encode(control), to: current)
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask,
                       onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        let next = orderWrite { worker in
            guard worker.wire.socket === current else { throw CancellationError() }
            onWriteStarted?()
            if worker.frameTrace != nil, case .string = message {
                worker.frameTrace?.record("control-write", attachment: worker.socketAttempts, message: message)
            }
            try await current.send(message)
        }
        do {
            try await next.value
            guard wire.socket === current else { throw CancellationError() }
        } catch {
            if wire.socket === current, state != .closing { lost(current) }
            throw error
        }
    }
}
