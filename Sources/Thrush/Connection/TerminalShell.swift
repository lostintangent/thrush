import Foundation
import Observation
import ThrushCore

/// A shell that a host can display in a terminal pane and observe from its tab or window.
///
/// Keep one instance per shell tab. A pane attaches when it becomes visible and
/// keeps the shell's title and exit state current as it receives output.
@MainActor @Observable public final class TerminalShell {
    /// The last title set by the shell. The initial title is empty.
    public private(set) var title = ""
    /// Whether the shell has exited or the host has closed it.
    public private(set) var hasExited = false

    package let connection: TerminalConnection

    /// Creates a shell for a stable, nonempty client identifier.
    ///
    /// The socket factory receives the identifier and measured grid dimensions on each
    /// attachment. Return a fresh, suspended WebSocket task. The host owns the session,
    /// and the shell manages the task.
    public convenience init(clientID: String,
                            makeSocket: @escaping @Sendable (String, Terminal.Size) throws -> URLSessionWebSocketTask) {
        self.init { observer in
            TerminalConnection(clientID: clientID, size: nil, observer: observer, makeSocket: makeSocket)
        }
    }

    package convenience init(baseURL: URL, clientID: String, size: Terminal.Size? = nil,
                             palette: Terminal.Palette = .default, onOutput: (@Sendable (Data) -> Void)? = nil,
                             frameTrace: (any ConnectionFrameObserver)? = nil) throws {
        try self.init { observer in
            try TerminalConnection(baseURL: baseURL, clientID: clientID, size: size, palette: palette,
                                   onOutput: onOutput, frameTrace: frameTrace, observer: observer)
        }
    }

    private init(makeConnection: (MetadataObserver) throws -> TerminalConnection) rethrows {
        let observer = MetadataObserver()
        connection = try makeConnection(observer)
        observer.shell = self
    }

    /// Ends this tab and asks the server to close its shell.
    ///
    /// If the socket is unavailable, the tab ends locally and the server releases the
    /// detached shell at its orphan deadline. A failed request throws an error.
    public func close() async throws { try await connection.closeShell() }

    /// The worker owns this observer. Its weak reference lets an outstanding socket
    /// read finish after the host releases the shell.
    @MainActor package final class MetadataObserver {
        fileprivate weak var shell: TerminalShell?
        private var latestRevision: UInt64 = 0

        func apply(title: String, hasExited: Bool, revision: UInt64) {
            guard let shell, revision > latestRevision else { return }
            latestRevision = revision
            if shell.title != title { shell.title = title }
            if shell.hasExited != hasExited { shell.hasExited = hasExited }
        }
    }
}
