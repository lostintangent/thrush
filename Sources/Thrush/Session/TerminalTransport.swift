import Foundation
import ThrushCore

/// An app’s transport to a terminal program, such as a local pseudoterminal or an SSH channel.
/// Return an open transport configured for the size supplied by `TerminalSession(openTransport:)`.
public protocol TerminalTransport: Sendable {
    /// Waits for output and returns the next available chunk. Return nil at EOF, after the final bytes.
    /// Thrush makes one read at a time and keeps reading while the view is hidden.
    func read() async throws -> Data?

    /// Delivers the entire buffer to the program. Keyboard input and terminal replies arrive in order.
    func write(_ bytes: Data) async throws

    /// Changes the program's terminal grid to the specified dimensions.
    func resize(to size: Terminal.Size) async throws

    /// Releases the transport and wakes any pending read, write or resize. May run concurrently with them.
    func close() async
}
