import Foundation
import Observation
import ThrushCore

/// A terminal session a host can observe and display in a pane.
///
/// Keep one session per tab or window. The pane attaches when visible, and the
/// session retains its screen and history while the pane is hidden.
@MainActor @Observable public final class TerminalSession {
    /// The last title set by the shell. The initial title is empty.
    public private(set) var title = ""
    /// Whether the shell has ended or the host has closed the session.
    public private(set) var hasEnded = false

    package let worker: TerminalWorker

    /// Creates a session that asks the host for a socket on each attachment.
    ///
    /// The factory receives the measured terminal size. Return a fresh, suspended
    /// task from the host's URLSession for the same remote shell on every attachment.
    public convenience init(makeSocket: @escaping @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init { observer in
            TerminalWorker(size: nil, observer: observer, makeSocket: makeSocket)
        }
    }

    /// Creates a session on a channel supplied by the host.
    ///
    /// The factory opens the program at the pane’s first measured grid size. The session
    /// keeps reading while the pane is hidden. After EOF or a transport failure, New Shell
    /// opens a fresh channel. Explicitly closing the session releases its channel permanently.
    public convenience init(openTransport: @escaping @Sendable (Terminal.Size) async throws -> any TerminalTransport) {
        self.init { observer in TerminalWorker(observer: observer, openTransport: openTransport) }
    }

    package convenience init(baseURL: URL, clientID: String, size: Terminal.Size? = nil,
                             palette: Terminal.Palette = .default, onOutput: (@Sendable (Data) -> Void)? = nil,
                             frameTrace: (any ConnectionFrameObserver)? = nil) throws {
        try self.init { observer in
            try TerminalWorker(baseURL: baseURL, clientID: clientID, size: size, palette: palette,
                               onOutput: onOutput, frameTrace: frameTrace, observer: observer)
        }
    }

    private init(makeWorker: (MetadataObserver) throws -> TerminalWorker) rethrows {
        let observer = MetadataObserver()
        worker = try makeWorker(observer)
        observer.session = self
    }

    deinit {
        let worker = worker
        Task { await worker.releaseStream() }
    }

    /// Ends this session and closes the host channel or asks the WebSocket server to close its shell.
    ///
    /// If the socket is unavailable, the session ends locally and the server releases the
    /// detached shell at its orphan deadline. A failed request throws an error.
    public func close() async throws { try await worker.closeShell() }

    /// The worker owns this observer. Its weak reference lets an outstanding transport
    /// read finish after the host releases the terminal session.
    @MainActor package final class MetadataObserver {
        fileprivate weak var session: TerminalSession?
        private var latestRevision: UInt64 = 0

        func apply(title: String, hasEnded: Bool, revision: UInt64) {
            guard let session, revision > latestRevision else { return }
            latestRevision = revision
            if session.title != title { session.title = title }
            if session.hasEnded != hasEnded { session.hasEnded = hasEnded }
        }
    }
}
