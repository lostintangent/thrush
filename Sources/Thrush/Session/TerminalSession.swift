import Foundation
import Observation
import ThrushCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A terminal session an app can observe and display in a ``TerminalView``.
///
/// Keep one session per tab or window. A ``TerminalView`` shows it while visible, and the
/// session retains its screen and history while the view is hidden.
@MainActor @Observable public final class TerminalSession {
    /// The last title set by the shell. The initial title is empty.
    public private(set) var title = ""
    /// Whether the shell exited, the app closed the session, or an app-supplied transport ended.
    /// An expired WebSocket shell is replaced in place.
    /// The final screen stays available. Create a new session to open a shell again.
    public private(set) var hasEnded = false

    package let actor: SessionActor

    /// Creates a session that asks the app for a socket on each attachment.
    ///
    /// The factory receives the measured terminal size. Return a fresh, suspended
    /// task from the app's URLSession with the same client ID on every attachment.
    public convenience init(makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init { observer in SessionActor(observer: observer, makeSocket: makeSocket) }
    }

    /// Creates a session on a transport supplied by the app.
    ///
    /// The factory opens the program at the view’s first measured grid size. The session
    /// keeps reading while the view is hidden. EOF, a transport failure, or an explicit
    /// close ends the session. Create a new session to open another transport.
    public convenience init(openTransport: @escaping @Sendable (Terminal.Size) async throws -> any TerminalTransport) {
        self.init { observer in SessionActor(observer: observer, openTransport: openTransport) }
    }

    private init(makeActor: (MetadataObserver) -> SessionActor) {
        let observer = MetadataObserver()
        actor = makeActor(observer)
        observer.session = self
    }

    deinit {
        let actor = actor
        Task { await actor.releaseSession() }
    }

    /// Ends the session and prevents it from opening another shell.
    ///
    /// For an app-supplied transport, Thrush calls its `close()` method. If the factory is
    /// still opening the transport, Thrush closes it when the factory returns.
    ///
    /// For a WebSocket, Thrush asks the server to end the shell. If the socket is
    /// unavailable or the request fails, the session ends locally and this method throws.
    /// The server releases any orphaned shell when its configured timeout expires.
    public func close() async throws { try await actor.closeShell() }

    /// A transport read can finish after the app releases the session.
    @MainActor final class MetadataObserver {
        fileprivate weak var session: TerminalSession?
        private var latestRevision: UInt64 = 0

        func apply(title: String, hasEnded: Bool, copiedText: String?, revision: UInt64) {
            guard let session, revision > latestRevision else { return }
            latestRevision = revision
            if session.title != title { session.title = title }
            if session.hasEnded != hasEnded { session.hasEnded = hasEnded }
            if let copiedText { Self.copyToPasteboard(copiedText) }
        }

        /// A program copies with OSC 52, such as a yank in Neovim or tmux.
        private static func copyToPasteboard(_ text: String) {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #else
            UIPasteboard.general.string = text
            #endif
        }
    }
}

extension TerminalSession {
    /// Each screen and its accompanying metadata come from the same turn of the session actor.
    enum Update: Sendable {
        case fresh(Terminal.Snapshot)
        case replaced(Terminal.Snapshot, shellRevision: UInt64)
        case awaitingReplay
        case screen(Terminal.Snapshot)
        case output(Terminal.Snapshot, receivedAt: TimeInterval?)
        case replay(Terminal.Snapshot, receivedAt: TimeInterval?)
        case reconnecting
        case displaced
        case ended(Terminal.Snapshot)
    }

    func show(userInitiated: Bool, theme: TerminalTheme, needsRetainedScreen: Bool) async
        -> (retainedScreen: Terminal.Snapshot?, status: Update?, shellRevision: UInt64) {
        await actor.show(userInitiated: userInitiated, palette: theme.palette, cursor: theme.cursor,
                         needsRetainedScreen: needsRetainedScreen)
    }

    func hide() async { await actor.hide() }

    func setTheme(_ theme: TerminalTheme) async { await actor.setPalette(theme.palette, cursor: theme.cursor) }

    func setFocused(_ focused: Bool) async throws { try await actor.setFocused(focused) }

    func send(_ input: Terminal.Input, forShell revision: UInt64) async throws {
        try await actor.send(input, forShell: revision)
    }

    func resize(to size: Terminal.Size, needsScreen: Bool) async throws -> Terminal.Snapshot? {
        try await actor.resize(to: size, needsScreen: needsScreen)
    }

    func statusAfterError() async -> Update? { await actor.statusAfterError() }
}

extension SessionActor {
    /// Ordinary output can run ahead of the view. A replay, lifecycle change or DEC synchronized
    /// output must reach the view in order before another socket message is consumed.
    func readUpdates(into output: OutputMailbox, notify: @escaping @MainActor @Sendable () -> Void,
                     deliver: @MainActor @Sendable (TerminalSession.Update) async -> Bool) async throws {
        var synchronized = terminal.modes.synchronizedOutput
        while !Task.isCancelled {
            let update = try await nextUpdate()
            try Task.checkCancellation()
            switch update {
            case .output(let screen, let receipt):
                let wasSynchronized = synchronized
                synchronized = screen.synchronizedOutputID != nil
                if !wasSynchronized, !synchronized {
                    if output.offer(screen, receivedAt: receipt) { Task { @MainActor in notify() } }
                    continue
                }
            case .fresh(let screen), .replaced(let screen, _), .screen(let screen), .replay(let screen, _):
                synchronized = screen.synchronizedOutputID != nil
            default:
                break
            }
            guard await deliver(update) else { return }
        }
    }
}

private extension SessionActor {
    func show(userInitiated: Bool, palette: Terminal.Palette, cursor: Terminal.RGB, needsRetainedScreen: Bool) async
        -> (retainedScreen: Terminal.Snapshot?, status: TerminalSession.Update?, shellRevision: UInt64) {
        // An app transport kept its shell while the view was hidden, so that shell hears a new appearance now.
        await setPalette(palette, cursor: cursor)
        let hadScreen = hasSeenReady
        show(userInitiated: userInitiated)
        if state == .ended { return (nil, .ended(snapshot()), shellRevision) }
        // An active app transport provides its current screen as the first update.
        let retainedScreen = needsRetainedScreen && hadScreen && state != .active ? snapshot() : nil
        return (retainedScreen, state == .displaced ? .displaced : nil, shellRevision)
    }

    func resize(to size: Terminal.Size, needsScreen: Bool) async throws -> Terminal.Snapshot? {
        try await sendResize(to: size)
        return needsScreen && state == .active ? snapshot() : nil
    }

    func nextUpdate() async throws -> TerminalSession.Update {
        switch try await nextEvent() {
        case .ready(resumed: true): .awaitingReplay
        case .ready(resumed: false): .fresh(snapshot())
        case .replaced: .replaced(snapshot(), shellRevision: shellRevision)
        case .screen: .screen(snapshot())
        case .output: .output(snapshot(), receivedAt: lastReceiptTime)
        case .replay: .replay(snapshot(), receivedAt: lastReceiptTime)
        case .reconnecting: .reconnecting
        case .displaced: .displaced
        case .exit: .ended(snapshot())
        }
    }

    func statusAfterError() -> TerminalSession.Update? {
        switch state {
        case .ended: .ended(snapshot())
        case .displaced: .displaced
        case .connecting, .reconnecting, .awaitingReplay: .reconnecting
        case .idle, .closing, .active: nil
        }
    }
}
