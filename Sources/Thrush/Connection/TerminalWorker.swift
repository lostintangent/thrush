import Foundation
import QuartzCore
import ThrushCore

/// Applies a session’s output, orders its input and owns its terminal independently of the pane.
package actor TerminalWorker {
    /// An attachment or screen update for a host running headlessly or driving its own view.
    ///
    /// A `TerminalPane` consumes these events when it presents the shell.
    package enum Event: Equatable, Sendable {
        /// The connection lost its transport or failed to open it. Read the next event to retry.
        case reconnecting
        /// Another attachment took over this shell. A user can reclaim it with ``TerminalWorker/attach(userInitiated:)``.
        case displaced
        /// The shell is ready. A resumed presentation gets the retained or replayed screen on its next output event.
        case ready(resumed: Bool)
        /// The terminal has an updated screen to display.
        case output
        /// The server restored a stalled live stream on the same socket. Replace the
        /// displayed screen and its row cache together from the updated terminal.
        case resynchronized
        /// The shell ended. All preceding output has been applied.
        case exit
    }

    /// The current phase of the shell attachment.
    package enum State: Equatable, Sendable {
        /// The worker is opening a channel or waiting for the server to accept an attachment.
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
        /// The worker is closing its transport.
        case closing
        /// The channel ended or the host closed the session.
        case ended
    }

    enum ConnectionError: Error {
        case unexpectedMessage, concurrentRead, inactiveAttachment, inputBufferFull
    }

    private let observer: TerminalSession.MetadataObserver?
    private var reportedTitle = ""
    private var reportedEnd = false
    private var metadataRevision: UInt64 = 0

    enum Transport {
        case webSocket(WebSocketTransport)
        case stream(StreamTransport)
    }

    let transport: Transport
    var stream: StreamTransport? {
        if case .stream(let stream) = transport { return stream }
        return nil
    }

    let frameTrace: (any ConnectionFrameObserver)?
    let onOutput: (@Sendable (Data) -> Void)?
    let sleepForRetry: @Sendable (Duration) async throws -> Void
    package internal(set) var hasSeenReady = false
    package internal(set) var exitedNaturally = false
    var wire: WebSocketAttachment
    var lifetime: UInt64 = 0
    var requestedSize: Terminal.Size
    var terminal: Terminal
    var lastWrite: Task<Void, Error>?

    /// Whether the most recent ready event opened a fresh shell after the previous shell disappeared.
    ///
    /// The first attachment and a user-initiated restart after natural exit both report `false`.
    package internal(set) var replacedPreviousShell = false
    package internal(set) var discardedHeldInputOnLastReady = false
    package internal(set) var isResynchronizing = false
    /// The connection's current attachment state.
    package internal(set) var state = State.detached
    package internal(set) var lastReceiptTime: CFTimeInterval?
    /// Number of WebSocket factory calls, including failed initial opens and retries.
    package internal(set) var socketAttempts = 0
    package internal(set) var receivedBytes = 0
    package internal(set) var appliedBytes = 0

    package init(baseURL: URL, clientID: String, size: Terminal.Size? = nil, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil) throws {
        let transport = try WebSocketTransport(baseURL: baseURL, clientID: clientID)
        self.init(transport: .webSocket(transport), size: size, palette: palette, onOutput: onOutput,
                  frameTrace: frameTrace, observer: observer)
    }

    package init(size: Terminal.Size?, palette: Terminal.Palette = .default,
                 onOutput: (@Sendable (Data) -> Void)? = nil, frameTrace: (any ConnectionFrameObserver)? = nil,
                 observer: TerminalSession.MetadataObserver? = nil,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                 makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init(transport: .webSocket(WebSocketTransport(makeSocket: makeSocket)), size: size, palette: palette,
                  onOutput: onOutput, frameTrace: frameTrace, observer: observer, sleepForRetry: sleepForRetry)
    }

    init(observer: TerminalSession.MetadataObserver, openTransport: @escaping StreamTransport.Open) {
        self.init(transport: .stream(StreamTransport(open: openTransport)), size: nil, palette: .default,
                  onOutput: nil, frameTrace: nil, observer: observer)
    }

    private init(transport: Transport, size: Terminal.Size?, palette: Terminal.Palette,
                 onOutput: (@Sendable (Data) -> Void)?, frameTrace: (any ConnectionFrameObserver)?,
                 observer: TerminalSession.MetadataObserver?,
                 sleepForRetry: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.observer = observer
        self.sleepForRetry = sleepForRetry
        self.frameTrace = frameTrace
        self.onOutput = onOutput
        self.transport = transport
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        wire = WebSocketAttachment(attachmentSize: initialSize)
        terminal = Terminal(size: initialSize, palette: palette)
        if case .webSocket(let webSocket) = transport, let size {
            socketAttempts += 1
            do {
                let first = try webSocket.makeSocket(size: size)
                wire.socket = first
                state = .connecting
                self.frameTrace?.record("open", attachment: socketAttempts)
                first.resume()
            } catch {
                state = .reconnecting
                wire.pendingEvent = .reconnecting
                wire.recovering = true
            }
        }
    }

    deinit {
        wire.retryWait?.cancel()
        wire.socket?.cancel(with: .goingAway, reason: nil)
    }

    /// A host can release its session while a raw read or write is still suspended.
    func releaseStream() async {
        if let stream, state != .ended { await endStream(stream, mayRestart: false) }
    }

    /// Starts an attachment for a detached tab.
    ///
    /// - Parameter userInitiated: Pass `true` when a person asks to reclaim a displaced
    ///   shell or start a new shell after natural exit. An explicitly closed tab stays ended.
    /// - Returns: `true` if an attachment attempt began. Read ``nextEvent()`` for its outcome.
    @discardableResult
    package func attach(userInitiated: Bool = false) -> Bool {
        if let stream, stream.presentation == nil, state == .active || state == .connecting || state == .closing {
            stream.observe()
            if state == .active {
                // The pane can show the existing terminal immediately, including output read while hidden.
                stream.presentation?.resumed = true
                stream.presentation?.hasOutput = true
                return false
            }
        }
        guard state == .detached || (userInitiated && (state == .displaced || (state == .ended && exitedNaturally))) else { return false }
        if exitedNaturally { hasSeenReady = false }
        exitedNaturally = false
        lifetime &+= 1
        if let stream {
            startStream(stream)
        } else {
            wire.pendingEvent = nil
            wire.isReading = false
            openSocket()
        }
        return true
    }

    /// Waits for the next presentation event. The pane owns one reader while visible.
    package func nextEvent() async throws -> Event {
        try Task.checkCancellation()
        if let stream { return try await nextStreamEvent(stream) }
        return try await nextSocketEvent()
    }

    func publishMetadata(title: String? = nil, hasEnded: Bool? = nil) async {
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
        if let stream {
            guard state == .active else { throw ConnectionError.inactiveAttachment }
            let bytes = terminal.encode(input)
            if !bytes.isEmpty { try await sendToStream(stream, .write(Data(bytes)), notify: notify) }
            return
        }
        try await sendSocketInput(input, notify: notify)
    }

    /// Requests a grid size for the shell and its local terminal.
    ///
    /// Before attachment, this sets the dimensions passed to the host’s factory.
    /// During attachment or replay, the connection applies the latest size after the
    /// server restores the grid at its negotiated dimensions.
    ///
    /// - Throws: A transport error if sending the resize fails.
    package func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        if let stream {
            if state == .active { try await resizeStream(stream) }
            return
        }
        guard let current = wire.socket, state == .active, !isResynchronizing else { return }
        try await resizeIfNeeded(current)
    }

    /// Ends this session permanently and releases its transport.
    ///
    /// This stops recovery and discards held input. If there is no socket to carry the
    /// request, the tab ends locally and the server's orphan deadline releases the shell.
    ///
    /// - Throws: An error if a close is already in progress or the connection cannot send the request.
    package func closeShell() async throws {
        if let stream {
            await endStream(stream, mayRestart: false)
            return
        }
        do { try await requestClose() }
        catch {
            if state == .ended { await publishMetadata(hasEnded: true) }
            throw error
        }
        await publishMetadata(hasEnded: true)
    }

    /// Stops presenting. A WebSocket detaches, while a host-supplied channel keeps draining.
    package func detach() {
        if let stream { stream.stopObserving() }
        else { detachSocket() }
    }

    /// Keystrokes, terminal replies and resizes reach the transport in the order accepted.
    func orderWrite(_ operation: @escaping @Sendable (isolated TerminalWorker) async throws -> Void) -> Task<Void, Error> {
        let previous = lastWrite
        let next = Task {
            try await previous?.value
            try await operation(self)
        }
        lastWrite = next
        return next
    }
}
