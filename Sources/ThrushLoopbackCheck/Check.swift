import Foundation
import Thrush
import ThrushConnection
import ThrushFixtures

/// Drives the same attachment, input and row access that a demo host uses.
@main
struct LoopbackCheck {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2, let endpoint = URL(string: CommandLine.arguments[1]) else {
            throw CheckFailure("Usage: ThrushLoopbackCheck SERVER_BASE_URL")
        }

        let fixture = try FirstBytesFixture.load()
        let size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)
        // A plus and a space round-trip distinctly through the real server's URLSearchParams.
        let clientID = "thrush + check"
        let connection = try TerminalConnection(baseURL: endpoint, clientID: clientID, size: size)
        guard try await connection.nextEvent() == .ready(resumed: false) else {
            throw CheckFailure("Expected fresh ready before output")
        }
        for (index, event) in fixture.events.enumerated() {
            guard try await connection.nextEvent() == .output else {
                throw CheckFailure("Expected binary output at chunk \(index)")
            }
            let row = await connection.text(inRow: event.row)
            guard row == event.text else {
                throw CheckFailure("Unexpected row at chunk \(index): \(row.debugDescription)")
            }
            if event.up != nil { try await connection.send(.key(.up)) }
        }
        try await connection.sendResize(to: .init(columns: size.columns + 1, rows: size.rows + 1))
        guard try await connection.nextEvent() == .exit,
              let final = fixture.events.last, await connection.text(inRow: final.row) == final.text
        else { throw CheckFailure("Expected the last output to remain readable at exit") }

        // A fresh shell at the same client ID tests explicit close independently of shell exit.
        let next = try TerminalConnection(baseURL: endpoint, clientID: clientID, size: size)
        guard try await next.nextEvent() == .ready(resumed: false),
              await next.text(inRow: 0).isEmpty
        else { throw CheckFailure("Expected a clean attachment after exit") }
        try await next.closeShell()
    }
}
