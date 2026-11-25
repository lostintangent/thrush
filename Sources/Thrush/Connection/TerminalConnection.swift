import Foundation
import QuartzCore
import ThrushCore

/// Owns the ordered WebSocket reader, input writes and terminal state for a shell.
package actor TerminalConnection {
    /// An attachment or screen update for a host running headlessly or driving its own view.
    ///
    /// A `TerminalPane` consumes these events when it presents the shell.
    package enum Event: Equatable, Sendable {
        /// The connection lost its transport or failed to open it. Read the next event to retry.
        case reconnecting
        /// Another attachment took over this shell. A user can reclaim it with ``TerminalConnection/attach(userInitiated:)``.
        case displaced
        /// The server accepted the attachment and the connection reset its terminal.
        ///
        /// A fresh shell is ready for input. When `resumed` is true, the next output event
        /// supplies the restored screen and input modes.
        case ready(resumed: Bool)
        /// The connection applied a binary frame of shell output or the initial replay.
        case output
        /// The server restored a stalled live stream on the same socket. Replace the
        /// displayed screen and its row cache together from the updated terminal.
        case resynchronized
        /// The server reported that the shell exited. All preceding output has been applied.
        case exit
    }

    /// The current phase of the shell attachment.
    package enum State: Equatable, Sendable {
        /// The connection opened a WebSocket task and is waiting for the server's ready message.
        case connecting
        /// The connection will retry a failed attachment when the host reads the next event.
        case reconnecting
        /// The server resumed a shell and the connection is restoring its screen and input modes.
        case replaying
        /// The connection accepts input and processes live shell output.
        case active
        /// The tab has no active attachment and can attach under the same client ID.
        case detached
        /// Another attachment took over the shell. Reattaching requires a user action.
        case displaced
        /// The connection is sending an explicit request to end the shell.
        case closing
        /// The shell exited or the host closed the tab. A user can start a new shell after a natural exit.
        case ended
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

    private let observer: TerminalSession.MetadataObserver?
    private var reportedTitle = ""
    private var reportedEnd = false
    private var metadataRevision: UInt64 = 0

    private let makeSocket: @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask
    private let frameTrace: (any ConnectionFrameObserver)?
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

    /// Whether the most recent ready event opened a fresh shell after the previous shell disappeared.
    ///
    /// The first attachment and a user-initiated restart after natural exit both report `false`.
    package private(set) var replacedPreviousShell = false
    package private(set) var discardedHeldInputOnLastReady = false
    package private(set) var isResynchronizing = false
    /// The connection's current attachment state.
    package private(set) var state = State.detached
    package private(set) var lastReceiptTime: CFTimeInterval?
    /// Number of transport factory calls, including failed initial opens and retries.
    package private(set) var socketAttempts = 0
    package private(set) var receivedBytes = 0
    package private(set) var appliedBytes = 0

    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil) throws {
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
        precondition(!clientID.isEmpty, "A shell needs a stable client ID")
        let owner = DemoSession()
        self.init(size: size, palette: palette, onOutput: onOutput,
                  frameTrace: frameTrace, observer: observer) { size in
            let url = try Self.url(for: endpoint, clientID: clientID, size: size)
            let task = owner.session.webSocketTask(with: url)
            // A single repaint can include a thousand rows of colored scrollback.
            task.maximumMessageSize = 64 * 1024 * 1024
            return task
        }
    }

    package init(size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil,
                 frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.observer = observer
        self.sleepForRetry = sleepForRetry
        self.frameTrace = frameTrace
        self.onOutput = onOutput
        self.makeSocket = makeSocket
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        attachmentSize = initialSize
        terminal = Terminal(size: initialSize, palette: palette)
        if let size {
            socketAttempts += 1
            do {
                let first = try makeSocket(size)
                socket = first
                state = .connecting
                self.frameTrace?.record("open", attachment: socketAttempts)
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

    /// Starts an attachment for a detached tab.
    ///
    /// - Parameter userInitiated: Pass `true` when a person asks to reclaim a displaced
    ///   shell or start a new shell after natural exit. An explicitly closed tab stays ended.
    /// - Returns: `true` if an attachment attempt began. Read ``nextEvent()`` for its outcome.
    @discardableResult
    package func attach(userInitiated: Bool = false) -> Bool {
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
            let next = try makeSocket(requestedSize)
            attachmentSize = requestedSize
            socket = next
            state = .connecting
            frameTrace?.record("open", attachment: socketAttempts)
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

    /// Waits for the next shell event for a headless host or a custom terminal view.
    ///
    /// Have one task make successive calls for the connection. A `TerminalPane` owns that
    /// reader when it presents the shell. Each output event arrives after the connection
    /// applies its bytes. Continue reading after ``Event/reconnecting`` to drive the retry.
    /// Stop after ``Event/displaced`` or ``Event/exit`` until another attachment begins.
    ///
    /// - Throws: An error if another read is in progress, the attachment is unavailable,
    ///   the operation is cancelled, or the server sends an invalid message.
    package func nextEvent() async throws -> Event {
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
        let attachment = socketAttempts
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await current.receive()
            frameTrace?.record("observed", attachment: attachment, message: message,
                               stale: lifetime != stamp || socket !== current)
        } catch {
            frameTrace?.record("receive-error", attachment: attachment, note: String(describing: error),
                               stale: lifetime != stamp || socket !== current, closeCode: current.closeCode.rawValue)
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
                    guard lifetime == stamp, pendingEvent != nil else { throw error }
                }
                guard lifetime == stamp else { throw CancellationError() }
                return resynchronized ? .resynchronized : .output

            case .string(let json):
                let control = try JSONDecoder().decode(ServerControl.self, from: Data(json.utf8))
                switch (control.type, state) {
                case (.ready, .connecting):
                    guard let resumed = control.resumed else { throw ConnectionError.unexpectedMessage }
                    frameTrace?.record("ready", attachment: attachment, message: message)
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
            if socket === current, state != .closing { park(as: .detached) }
            throw error
        }
    }

    private func publishMetadata(title: String? = nil, hasEnded: Bool? = nil) async {
        guard let observer else { return }
        let title = title ?? reportedTitle
        let hasEnded = hasEnded ?? reportedEnd
        guard title != reportedTitle || hasEnded != reportedEnd else { return }
        reportedTitle = title
        reportedEnd = hasEnded
        metadataRevision &+= 1
        await observer.apply(title: title, hasEnded: hasEnded, revision: metadataRevision)
    }

    package func finishFrameTrace(_ result: String) async {
        await frameTrace?.finish(result, attachment: socketAttempts, received: receivedBytes, applied: appliedBytes)
    }

    private func takePendingEvent() -> Event? {
        defer { pendingEvent = nil }
        return pendingEvent
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }

    package func snapshot() -> Terminal.Snapshot { terminal.snapshot() }

    /// A value copy of the terminal at the time of the read.
    ///
    /// Inspect its rows headlessly or pass it to a native terminal view for display.
    /// Subsequent output updates the connection's terminal independently of this copy.
    package var currentTerminal: Terminal { terminal }

    /// Sets the colors reported to programs that query the terminal, including while the view is hidden.
    package func setPalette(_ palette: Terminal.Palette) { terminal.palette = palette }

    /// Encodes input using the shell's current modes and sends it over the active attachment.
    ///
    /// During automatic recovery, the connection holds text, paste and keys until replay
    /// restores the same shell's modes. It drops pointer input during recovery and discards
    /// held input if the server opens a fresh shell. The queue holds up to 256 inputs and
    /// 64 KiB, counting UTF-8 bytes for text and character keys and one byte for other keys.
    ///
    /// - Throws: An error if the new input would exceed either limit, the connection is
    ///   unavailable, or its write fails.
    package func send(_ input: Terminal.Input) async throws {
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

    /// Requests a grid size for the shell and its local terminal.
    ///
    /// Before attachment, this sets the dimensions passed to the socket factory.
    /// During attachment or replay, the connection applies the latest size after the
    /// server restores the grid at its negotiated dimensions.
    ///
    /// - Throws: A transport error if sending the resize fails.
    package func sendResize(to size: Terminal.Size) async throws {
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

    /// Ends this tab permanently and asks the server to close its shell.
    ///
    /// This stops recovery and discards held input. If there is no socket to carry the
    /// request, the tab ends locally and the server's orphan deadline releases the shell.
    ///
    /// - Throws: An error if a close is already in progress or the connection cannot send the request.
    package func closeShell() async throws {
        do { try await requestClose() }
        catch {
            if state == .ended { await publishMetadata(hasEnded: true) }
            throw error
        }
        await publishMetadata(hasEnded: true)
    }

    private func requestClose() async throws {
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

    /// Releases the socket, cancels retries and discards held input while keeping the tab's terminal.
    ///
    /// The server keeps the detached shell until its orphan deadline. Call ``attach(userInitiated:)``
    /// to reattach when the tab becomes visible again.
    package func detach() {
        frameTrace?.record("detach", attachment: socketAttempts)
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
        if let current {
            frameTrace?.record("cancel", attachment: socketAttempts, closeCode: current.closeCode.rawValue)
            current.cancel(with: .normalClosure, reason: nil)
        }
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
            if self.frameTrace != nil, case .string = message {
                self.frameTrace?.record("control-write", attachment: self.socketAttempts, message: message)
            }
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
