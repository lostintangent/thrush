import Foundation
import QuartzCore
import ThrushCore

/// Applies a session’s output, orders its input and owns its terminal independently of its view.
package actor SessionActor {
    /// Changes a session sends to its visible view or headless reader.
    package enum Event: Equatable, Sendable {
        /// Read the next event to retry the WebSocket.
        case reconnecting
        /// Another WebSocket attachment took over the shell.
        case displaced
        /// The shell opened. A resumed WebSocket delivers its replay next.
        case ready(resumed: Bool)
        /// The app transport kept reading while hidden. Display its current screen.
        case screen
        /// The terminal applied new program output.
        case output
        /// The terminal applied the WebSocket server's complete replay.
        case replay
        /// The shell ended after its final output.
        case exit
    }

    package enum State: Equatable, Sendable {
        case idle, connecting, active, closing, ended
        // Only the WebSocket protocol has retries, replay and attachment takeover.
        case reconnecting, awaitingReplay, displaced
    }

    enum TransportError: Error {
        case unexpectedMessage, concurrentRead, inactiveTransport, inputBufferFull
    }

    enum Transport {
        case webSocket(WebSocketTransport)
        case app(AppTransport)
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

    /// Shows the session. Returns true when it starts opening a transport.
    /// Only a user action can reclaim a displaced shell or restart an ended one.
    @discardableResult
    package func show(userInitiated: Bool = false) -> Bool {
        switch transport {
        case .webSocket(let socket): socket.attach(to: self, userInitiated: userInitiated)
        case .app(let app): app.show(in: self, userInitiated: userInitiated)
        }
    }

    func beginOpening(userInitiated: Bool) -> Bool {
        switch state {
        case .idle: break
        case .displaced where userInitiated: break
        case .ended where userInitiated && exitedNaturally: hasSeenReady = false
        default: return false
        }
        exitedNaturally = false
        lifetime &+= 1
        return true
    }

    /// The view owns one event reader while visible.
    package func nextEvent() async throws -> Event {
        try Task.checkCancellation()
        return switch transport {
        case .webSocket(let socket): try await socket.nextEvent(in: self)
        case .app(let app): try await app.nextEvent(in: self)
        }
    }

    /// Encodes input using the program's current modes. The latency probe runs as the write begins.
    package func send(_ input: Terminal.Input, onWriteStarted: (@Sendable () -> Void)? = nil) async throws {
        switch transport {
        case .webSocket(let socket): try await socket.send(input, in: self, notify: onWriteStarted)
        case .app(let app): try await app.send(input, in: self, notify: onWriteStarted)
        }
    }

    /// Remembers the latest measured grid, including while the transport is opening.
    package func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        switch transport {
        case .webSocket(let socket): try await socket.resize(in: self)
        case .app(let app): try await app.resize(in: self)
        }
    }

    package func hide() {
        switch transport {
        case .webSocket(let socket): socket.detach(from: self)
        case .app(let app): app.hide(in: self)
        }
    }

    package func closeShell() async throws {
        switch transport {
        case .webSocket(let socket): try await socket.close(in: self)
        case .app(let app): await app.close(in: self)
        }
    }

    func releaseSession() async {
        switch transport {
        // A suspended reader may still own this actor after the app releases its session.
        case .webSocket(let socket): socket.detach(from: self)
        case .app(let app): await app.release(in: self)
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
    package func setPalette(_ palette: Terminal.Palette, cursor: Terminal.RGB) {
        terminal.palette = palette
        terminal.cursorColor = cursor
    }

    /// Records whether the view has keyboard focus and tells a program that asked. A shell that isn't
    /// attached hears the current focus when its replay sets mode 1004 again.
    package func setFocused(_ focused: Bool) async throws {
        guard terminal.isFocused != focused else { return }
        terminal.isFocused = focused
        try await send(.focus(focused))
    }

    /// A new shell or a replay starts from a blank terminal that keeps the host's theme and focus.
    func resetTerminal(size: Terminal.Size) {
        var next = Terminal(size: size, palette: terminal.palette, cursorColor: terminal.cursorColor)
        next.isFocused = terminal.isFocused
        terminal = next
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

    /// Keystrokes, terminal replies and resizes reach the transport in the order accepted.
    func orderWrite(_ operation: @escaping @Sendable (isolated SessionActor) async throws -> Void) -> Task<Void, Error> {
        let previous = lastWrite
        let next = Task {
            try await previous?.value
            try await operation(self)
        }
        lastWrite = next
        return next
    }
}
