import Foundation
import QuartzCore
import Thrush

/// A host keeps one connection per shell tab, including while its view is backgrounded.
/// Pull one event at a time. A ready event replaces the grid and invalidates the view's row cache.
public actor TerminalConnection {
    /// Each event follows the preceding one on the same WebSocket. Binary output is already applied.
    public enum Event: Equatable, Sendable {
        case reconnecting, displaced
        case ready(resumed: Bool)
        case output
        /// The server replaced a stalled live stream with a serialized screen on the same socket.
        /// Reset the view's row cache and display the new terminal in the same UI update.
        case resynchronized
        case exit
    }

    /// A displaced tab remains idle until a person asks to reclaim it. Ended is terminal.
    public enum State: Equatable, Sendable {
        case connecting, reconnecting, replaying, active, detached, displaced, closing, ended
    }

    private enum ConnectionError: Error {
        case invalidEndpoint, unexpectedMessage, concurrentRead, inactiveAttachment, inputBufferFull
    }

    private struct ServerControl: Decodable {
        enum Kind: String, Decodable { case ready, exit }
        let type: Kind
        let resumed: Bool?
    }

    private struct ClientControl: Encodable {
        enum Kind: String, Encodable { case resize, close }
        let type: Kind
        var cols: Int?
        var rows: Int?
    }

    /// Only the convenience initializer owns a session. A host keeps ownership of its own session.
    private final class DemoSession: Sendable {
        let session = URLSession(configuration: .ephemeral)
        deinit { session.invalidateAndCancel() }
    }

    private let makeSocket: @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask
    private let clientID: String
    private let onOutput: (@Sendable (Data) -> Void)?
    private let sleepForRetry: @Sendable (Duration) async throws -> Void
    private var retryWait: Task<Void, Error>?
    private var retryMilliseconds = 250
    private var pendingEvent: Event?
    package private(set) var hasSeenReady = false
    package private(set) var exitedNaturally = false
    private var recovering = false
    private var lifetime: UInt64 = 0
    private var heldInput: [HeldInput] = []
    private var heldBytes = 0

    private struct HeldInput {
        let input: Terminal.Input
        let byteCount: Int
        let onWriteStarted: (@Sendable () -> Void)?
    }

    private var socket: URLSessionWebSocketTask?
    private var requestedSize: Terminal.Size
    private var attachmentSize: Terminal.Size
    private var terminal: Terminal
    private var isReading = false
    private var lastWrite: Task<Void, Error>?

    /// True at fresh ready when a previously attached shell disappeared. A user's intentional
    /// restart after natural exit starts a new shell without reporting an unexpected replacement.
    public private(set) var replacedPreviousShell = false
    package private(set) var discardedHeldInputOnLastReady = false
    package private(set) var isResynchronizing = false
    public private(set) var state = State.detached
    package private(set) var lastReceiptTime: CFTimeInterval?
    /// Number of transport factory calls, including failed initial opens and retries.
    package private(set) var socketAttempts = 0
    package private(set) var receivedBytes = 0
    package private(set) var appliedBytes = 0

    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil) throws {
        guard var location = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              location.host != nil, location.query == nil, location.fragment == nil
        else { throw ConnectionError.invalidEndpoint }
        switch location.scheme {
        case "http", "ws": location.scheme = "ws"
        case "https", "wss": location.scheme = "wss"
        default: throw ConnectionError.invalidEndpoint
        }
        location.path = baseURL.appending(path: "socket").path
        let endpoint = location
        let owner = DemoSession()
        self.init(clientID: clientID, size: size, palette: palette, onOutput: onOutput) { id, size in
            let url = try Self.url(for: endpoint, clientID: id, size: size)
            return owner.session.webSocketTask(with: url)
        }
    }

    /// Create a detached shell tab. A native view supplies its first measured size with
    /// sendResize(to:) before attaching. A headless caller can use the default 80 × 24.
    /// Return a fresh, suspended WebSocket task from the host's session on every attachment.
    public init(clientID: String, palette: Terminal.Palette = .default,
                makeSocket: @escaping @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init(clientID: clientID, size: nil, palette: palette, onOutput: nil, makeSocket: makeSocket)
    }

    package init(clientID: String, size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask) {
        precondition(!clientID.isEmpty, "A shell needs a stable client ID")
        self.sleepForRetry = sleepForRetry
        self.clientID = clientID
        self.onOutput = onOutput
        self.makeSocket = makeSocket
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        attachmentSize = initialSize
        terminal = Terminal(size: initialSize, palette: palette)
        if let size {
            socketAttempts += 1
            do {
                let first = try makeSocket(clientID, size)
                socket = first
                state = .connecting
                first.resume()
            } catch {
                state = .reconnecting
                pendingEvent = .reconnecting
                recovering = true
            }
        }
    }

    deinit {
        retryWait?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
    }

    /// Attach on foreground return. Use an explicit user action to reclaim a displaced shell
    /// or open a new shell after natural exit. An explicitly closed tab stays ended.
    @discardableResult
    public func attach(userInitiated: Bool = false) -> Bool {
        guard state == .detached || (userInitiated && (state == .displaced || exitedNaturally)) else { return false }
        if exitedNaturally { hasSeenReady = false }
        exitedNaturally = false
        pendingEvent = nil
        isReading = false
        lifetime &+= 1
        openSocket()
        return true
    }

    private func openSocket() {
        socketAttempts += 1
        do {
            let next = try makeSocket(clientID, requestedSize)
            attachmentSize = requestedSize
            socket = next
            state = .connecting
            next.resume()
        } catch {
            beginRecovery()
        }
    }

    private static func url(for endpoint: URLComponents, clientID: String, size: Terminal.Size) throws -> URL {
        var location = endpoint
        location.queryItems = [
            URLQueryItem(name: "service", value: "terminal"),
            URLQueryItem(name: "clientId", value: clientID),
            URLQueryItem(name: "cols", value: String(size.columns)),
            URLQueryItem(name: "rows", value: String(size.rows)),
        ]
        // URLSearchParams on the server decodes an unescaped plus as a space.
        location.percentEncodedQuery = location.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = location.url else { throw ConnectionError.invalidEndpoint }
        return url
    }

    /// Keep pulling after reconnecting. One pull waits for the retry delay and requests the
    /// next message. Displacement and exit park this pump until a user asks to attach again.
    public func nextEvent() async throws -> Event {
        try Task.checkCancellation()
        guard !isReading else { throw ConnectionError.concurrentRead }
        isReading = true
        let stamp = lifetime
        defer { if lifetime == stamp { isReading = false } }

        if let event = takePendingEvent() { return event }
        if state == .reconnecting {
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
            guard lifetime == stamp, state == .reconnecting else { throw CancellationError() }
            retryWait = nil
            openSocket()
            if let event = takePendingEvent() { return event }
        }

        guard let current = socket, state != .closing else { throw ConnectionError.inactiveAttachment }
        // An in-band ready and its following binary replay publish one complete generation.
        while true {
            if let event = try await receiveEvent(from: current, lifetime: stamp) { return event }
        }
    }

    private func receiveEvent(from current: URLSessionWebSocketTask, lifetime stamp: UInt64) async throws -> Event? {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
        } catch {
            guard lifetime == stamp, state != .closing else { throw CancellationError() }
            if socket === current { lost(current) }
            if let event = takePendingEvent() { return event }
            throw error
        }
        guard lifetime == stamp else { throw CancellationError() }
        guard socket === current else {
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
                let resynchronized = isResynchronizing
                if resynchronized {
                    // No actor suspension between resetting the parser and applying the checkpoint.
                    // The old grid kept its negotiated size while the new checkpoint was in flight.
                    terminal = Terminal(size: terminal.size, palette: terminal.palette)
                    isResynchronizing = false
                }
                let reply = bytes.withUnsafeBytes { terminal.receive($0.bindMemory(to: UInt8.self)) }
                appliedBytes += bytes.count
                onOutput?(bytes)
                do {
                    if !reply.isEmpty && state != .closing { try await write(.data(Data(reply)), to: current) }
                    if state == .replaying { try await activate(current) }
                    if resynchronized && state == .active { try await resizeIfNeeded(current) }
                } catch {
                    // Output was already applied. Present it before reporting its reply's transport failure.
                    guard lifetime == stamp, pendingEvent != nil else { throw error }
                }
                guard lifetime == stamp else { throw CancellationError() }
                return resynchronized ? .resynchronized : .output

            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    replacedPreviousShell = hasSeenReady && !resumed
                    discardedHeldInputOnLastReady = !resumed && !heldInput.isEmpty
                    hasSeenReady = true
                    retryMilliseconds = 250
                    terminal = Terminal(size: attachmentSize, palette: terminal.palette)
                    lastReceiptTime = nil
                    if resumed {
                        state = .replaying
                    } else {
                        discardHeldInput()
                        do { try await activate(current) }
                        catch { guard lifetime == stamp, pendingEvent != nil else { throw error } }
                    }
                    guard lifetime == stamp else { throw CancellationError() }
                    return .ready(resumed: resumed)
                case (.ready, .active) where control.resumed == true && !isResynchronizing:
                    isResynchronizing = true
                    return nil
                case (.exit, .active), (.exit, .closing):
                    if state != .closing {
                        park(as: .ended)
                        exitedNaturally = true
                    }
                    return .exit
                default: throw ConnectionError.unexpectedMessage
                }
            @unknown default: throw ConnectionError.unexpectedMessage
            }
        } catch {
            // A malformed server frame fails the protocol. Retrying the same endpoint could
            // otherwise repeat that error forever.
            if socket === current, state != .closing { park(as: .detached) }
            throw error
        }
    }

    private func takePendingEvent() -> Event? {
        defer { pendingEvent = nil }
        return pendingEvent
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }

    package func snapshot() -> Terminal.Snapshot { terminal.snapshot() }

    /// A value snapshot from the same serial owner that applies output and encodes keystrokes.
    /// Pass this to TerminalView.display on the main actor. Retain it only as long as the view needs it.
    public var currentTerminal: Terminal { terminal }

    /// Set the colors used for queries from the running program, including while the view is hidden.
    public func setPalette(_ palette: Terminal.Palette) { terminal.palette = palette }

    /// During automatic recovery, hold up to 256 inputs and 64 KiB of source text. A full
    /// queue rejects the newest input as a whole. Resumed modes determine its eventual encoding.
    public func send(_ input: Terminal.Input) async throws {
        try await send(input, notify: nil)
    }

    /// The host's latency probe timestamps the first actual write attempt for this input.
    package func send(_ input: Terminal.Input, onWriteStarted: @escaping @Sendable () -> Void) async throws {
        try await send(input, notify: onWriteStarted)
    }

    private func send(_ input: Terminal.Input, notify: (@Sendable () -> Void)?) async throws {
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
        guard let current = socket, state == .active else { throw ConnectionError.inactiveAttachment }
        try await send(input, on: current, notify: notify)
    }

    private func send(_ input: Terminal.Input, on current: URLSessionWebSocketTask,
                      notify: (@Sendable () -> Void)?) async throws {
        let bytes = terminal.encode(input)
        if !bytes.isEmpty { try await write(.data(Data(bytes)), to: current, onWriteStarted: notify) }
    }

    /// A size change during attach is sent after ready and any replay at the URL's original size.
    public func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        guard let current = socket, state == .active, !isResynchronizing else { return }
        try await resizeIfNeeded(current)
    }

    private func activate(_ current: URLSessionWebSocketTask) async throws {
        // A second loss drops only an attempted write, whose delivery is ambiguous. Later keys
        // still belong to the unsent queue and will use the next resumed shell's input modes.
        while socket === current && state != .closing {
            if terminal.size != requestedSize {
                try await resizeIfNeeded(current)
            } else if !heldInput.isEmpty {
                let next = heldInput.removeFirst()
                heldBytes -= next.byteCount
                try await send(next.input, on: current, notify: next.onWriteStarted)
            } else {
                recovering = false
                state = .active
                return
            }
        }
        throw CancellationError()
    }

    private func resizeIfNeeded(_ current: URLSessionWebSocketTask) async throws {
        guard terminal.size != requestedSize else { return }
        terminal.resize(to: requestedSize)
        try await writeControl(ClientControl(type: .resize, cols: requestedSize.columns, rows: requestedSize.rows),
                               to: current)
    }

    /// Explicit close stops recovery. With no transport to carry the close control, the tab
    /// still ends locally and throws. The server's orphan deadline then releases the remote PTY.
    public func closeShell() async throws {
        exitedNaturally = false
        guard state != .closing else { throw ConnectionError.inactiveAttachment }
        guard let current = socket else {
            park(as: .ended)
            throw ConnectionError.inactiveAttachment
        }
        state = .closing
        discardHeldInput()
        defer { if socket === current { park(as: .ended) } }
        try await writeControl(ClientControl(type: .close), to: current)
    }

    /// Release the attachment and any retry delay when the view leaves the foreground.
    public func detach() {
        guard state != .displaced, state != .ended, state != .closing else { return }
        park(as: socket?.closeCode.rawValue == 4000 ? .displaced : .detached)
    }

    private func discardHeldInput() {
        heldInput.removeAll()
        heldBytes = 0
        recovering = false
    }

    private func releaseSocket() {
        isResynchronizing = false
        let current = socket
        socket = nil
        lastWrite = nil
        current?.cancel(with: .normalClosure, reason: nil)
    }

    private func park(as state: State) {
        lifetime &+= 1
        isReading = false
        retryWait?.cancel()
        retryWait = nil
        retryMilliseconds = 250
        pendingEvent = nil
        discardHeldInput()
        releaseSocket()
        self.state = state
    }

    private func beginRecovery() {
        recovering = true
        state = .reconnecting
        pendingEvent = .reconnecting
    }

    private func lost(_ current: URLSessionWebSocketTask) {
        let displaced = current.closeCode.rawValue == 4000
        releaseSocket()
        if displaced {
            discardHeldInput()
            retryMilliseconds = 250
            state = .displaced
            pendingEvent = .displaced
        } else {
            beginRecovery()
        }
    }

    private func writeControl(_ control: ClientControl, to current: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(control)
        try await write(.string(String(decoding: bytes, as: UTF8.self)), to: current)
    }

    /// Actor methods can interleave at send and receive. Every queued write and its completion
    /// belong to the socket captured when the operation began.
    private func write(_ message: URLSessionWebSocketTask.Message, to current: URLSessionWebSocketTask,
                       onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        let previous = lastWrite
        let next = Task {
            try await previous?.value
            guard self.socket === current else { throw CancellationError() }
            onWriteStarted?()
            try await current.send(message)
        }
        lastWrite = next
        do {
            try await next.value
            guard socket === current else { throw CancellationError() }
        } catch {
            if socket === current, state != .closing { lost(current) }
            throw error
        }
    }
}
