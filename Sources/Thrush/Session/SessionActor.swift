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
        /// The old shell expired. Its main screen is in history and the new shell accepts input.
        case replaced
        /// The app transport kept reading while hidden. Display its current screen.
        case screen
        /// The terminal applied new program output.
        case output
        /// The terminal applied the WebSocket server's complete replay.
        case replay
        /// The session ended. Its final screen stays.
        case ended
    }

    package enum State: Equatable, Sendable {
        case idle, connecting, live, closing, ended
        // Only the WebSocket protocol has retries, replay and attachment takeover.
        case reconnecting, awaitingReplay, displaced
    }

    enum TransportError: Error {
        case unexpectedMessage, concurrentRead, inactiveTransport, inputBufferFull
    }

    /// Carries the shell's output in and the session's writes out. Each transport runs on its
    /// session's actor.
    protocol Transport: AnyObject {
        /// Returns true when it starts opening.
        func show(userInitiated: Bool, in session: isolated SessionActor) -> Bool
        func hide(in session: isolated SessionActor)
        func nextEvent(in session: isolated SessionActor) async throws -> Event
        func send(_ input: Terminal.Input, in session: isolated SessionActor) async throws
        /// Applies the session's requested size once the shell can take it.
        func resize(in session: isolated SessionActor) async throws
        func close(in session: isolated SessionActor) async throws
        /// The app released the session while a suspended reader may still hold its actor.
        func release(in session: isolated SessionActor) async
    }

    let transport: any Transport
    var terminal: Terminal
    var requestedSize: Terminal.Size
    /// Opening, parking or closing a transport starts a new lifetime. Work begun in an earlier one is cancelled.
    var lifetime: UInt64 = 0
    // A native action may still be queued for the screen displayed before a replacement.
    var shellRevision: UInt64 = 0
    var lastWrite: Task<Void, Error>?

    package internal(set) var state: State
    package internal(set) var hasSeenReady = false
    package internal(set) var lastReceiptTime: CFTimeInterval?
    package private(set) var receivedBytes = 0
    package private(set) var appliedBytes = 0

    private let observer: TerminalSession.MetadataObserver?
    private var reportedTitle = ""
    private var reportedEnd = false
    private var metadataRevision: UInt64 = 0

    init(transport: any Transport, size: Terminal.Size?, palette: Terminal.Palette, state: State,
         observer: TerminalSession.MetadataObserver?) {
        self.transport = transport
        self.state = state
        self.observer = observer
        let initialSize = size ?? .init(columns: 80, rows: 24)
        requestedSize = initialSize
        terminal = Terminal(size: initialSize, palette: palette)
    }

    /// Shows the session. Returns true when it starts opening a transport.
    /// Only a user action can reclaim a displaced shell. An ended session stays ended.
    @discardableResult
    package func show(userInitiated: Bool = false) -> Bool { transport.show(userInitiated: userInitiated, in: self) }

    func beginOpening(userInitiated: Bool = false) -> Bool {
        switch state {
        case .idle: break
        case .displaced where userInitiated: break
        default: return false
        }
        lifetime &+= 1
        return true
    }

    /// Throws when work begun at `stamp` belongs to an earlier lifetime.
    func checkLifetime(_ stamp: UInt64) throws {
        guard lifetime == stamp else { throw CancellationError() }
    }

    /// The view owns one event reader while visible.
    package func nextEvent() async throws -> Event {
        try Task.checkCancellation()
        return try await transport.nextEvent(in: self)
    }

    /// Encodes input using the program's current modes.
    package func send(_ input: Terminal.Input, forShell revision: UInt64? = nil) async throws {
        if let revision, revision != shellRevision { return }
        try await transport.send(input, in: self)
    }

    /// Remembers the latest measured grid, including while the transport is opening.
    package func sendResize(to size: Terminal.Size) async throws {
        requestedSize = size
        try await transport.resize(in: self)
    }

    package func hide() { transport.hide(in: self) }

    package func closeShell() async throws { try await transport.close(in: self) }

    func releaseSession() async { await transport.release(in: self) }

    func recordReceipt(of bytes: Data) {
        lastReceiptTime = CACurrentMediaTime()
        receivedBytes += bytes.count
    }

    func apply(_ bytes: Data) -> [UInt8] {
        let reply = terminal.write(Span(viewing: bytes.bytes))
        appliedBytes += bytes.count
        return reply
    }

    package func text(inRow row: Int) -> String { terminal.text(inRow: row) }
    package func snapshot() -> Terminal.Snapshot { terminal.snapshot() }
    package var currentTerminal: Terminal { terminal }

    /// Applies the app's theme. Its background decides whether the theme is dark or light, whatever
    /// colors the program set, and a program that set mode 2031 hears each change.
    package func setPalette(_ palette: Terminal.Palette, cursor: Terminal.RGB) async {
        terminal.palette = palette
        terminal.cursorColor = cursor
        let appearance: Terminal.Appearance = palette.background.isDark ? .dark : .light
        guard appearance != terminal.appearance else { return }
        terminal.appearance = appearance
        // A shell that isn't live hears the current appearance once a resumed attachment activates.
        if state == .live { try? await send(.appearance(appearance)) }
    }

    /// Records whether the view has keyboard focus and tells a program that asked. A shell that isn't
    /// attached hears the current focus when its replay sets mode 1004 again.
    package func setFocused(_ focused: Bool) async throws {
        guard terminal.isFocused != focused else { return }
        terminal.isFocused = focused
        try await send(.focus(focused))
    }

    /// A first attachment starts from a blank terminal with the app's theme and focus.
    func resetTerminal(size: Terminal.Size) {
        var next = Terminal(size: size, palette: terminal.palette, cursorColor: terminal.cursorColor)
        next.isFocused = terminal.isFocused
        next.appearance = terminal.appearance
        terminal = next
    }

    func publishMetadata(title: String? = nil, hasEnded: Bool? = nil) async {
        guard let observer else { return }
        let title = title ?? reportedTitle
        let hasEnded = hasEnded ?? reportedEnd
        let copiedText = terminal.copiedText.take()
        guard title != reportedTitle || hasEnded != reportedEnd || copiedText != nil else { return }
        reportedTitle = title
        reportedEnd = hasEnded
        metadataRevision &+= 1
        await observer.apply(title: title, hasEnded: hasEnded, copiedText: copiedText, revision: metadataRevision)
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
