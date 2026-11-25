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

    enum Transport {
        case webSocket(WebSocketTransport)
        case hostChannel(HostChannelState)
    }

    let transport: Transport
    var terminal: Terminal
    var requestedSize: Terminal.Size
    var lifetime: UInt64 = 0
    var lastWrite: Task<Void, Error>?

    package internal(set) var state: State
    package internal(set) var hasSeenReady = false
    package internal(set) var exitedNaturally = false
    package internal(set) var lastReceiptTime: CFTimeInterval?
    package private(set) var receivedBytes = 0
    package private(set) var appliedBytes = 0

    private let observer: TerminalSession.MetadataObserver?
    private var reportedTitle = ""
    private var reportedEnd = false
    private var metadataRevision: UInt64 = 0

    init(transport: Transport, size: Terminal.Size?, palette: Terminal.Palette, state: State,
         observer: TerminalSession.MetadataObserver?) {
        self.transport = transport
        self.state = state
        self.observer = observer
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        terminal = Terminal(size: initialSize, palette: palette)
    }

    /// Begins presenting a shell. Returns true when a new attachment begins.
    /// Only a user action can reclaim a displaced shell or restart an ended one.
    @discardableResult
    package func attach(userInitiated: Bool = false) -> Bool {
        switch transport {
        case .webSocket(let socket): socket.attach(to: self, userInitiated: userInitiated)
        case .hostChannel(let host): host.attach(to: self, userInitiated: userInitiated)
        }
    }

    func beginAttachment(userInitiated: Bool) -> Bool {
        switch state {
        case .detached: break
        case .displaced where userInitiated: break
        case .ended where userInitiated && exitedNaturally: hasSeenReady = false
        default: return false
        }
        exitedNaturally = false
        lifetime &+= 1
        return true
    }

    /// The pane owns one event reader while visible.
    package func nextEvent() async throws -> Event {
        try Task.checkCancellation()
        return switch transport {
        case .webSocket(let socket): try await socket.nextEvent(in: self)
        case .hostChannel(let host): try await host.nextEvent(in: self)
        }
    }

    /// Encodes input using the program's current modes. The latency probe runs as the write begins.
    package func send(_ input: Terminal.Input, onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        switch transport {
        case .webSocket(let socket): try await socket.send(input, in: self, notify: onWriteStarted)
        case .hostChannel(let host): try await host.send(input, in: self, notify: onWriteStarted)
        }
    }

    /// Remembers the latest measured grid, including while a channel is opening.
    package func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        switch transport {
        case .webSocket(let socket): try await socket.resize(in: self)
        case .hostChannel(let host): try await host.resize(in: self)
        }
    }

    package func detach() {
        switch transport {
        case .webSocket(let socket): socket.detach(from: self)
        case .hostChannel(let host): host.detach(from: self)
        }
    }

    package func closeShell() async throws {
        switch transport {
        case .webSocket(let socket): try await socket.close(in: self)
        case .hostChannel(let host): await host.close(in: self)
        }
    }

    func releaseSession() async {
        switch transport {
        case .webSocket: break  // Releasing its worker drops the socket.
        case .hostChannel(let host): await host.release(in: self)
        }
    }

    func recordReceipt(of bytes: Data) {
        lastReceiptTime = CACurrentMediaTime()
        receivedBytes += bytes.count
    }

    func apply(_ bytes: Data) -> [UInt8] {
        let reply = terminal.receive(Span(viewing: bytes.bytes))
        appliedBytes += bytes.count
        return reply
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }
    package func snapshot() -> Terminal.Snapshot { terminal.snapshot() }
    package var currentTerminal: Terminal { terminal }
    package func setPalette(_ palette: Terminal.Palette) { terminal.palette = palette }

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
