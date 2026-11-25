import Foundation
import Thrush
import ThrushFixtures

extension LoopbackCheck {
    /// Exercise the same socket and parser as the native hosts against an input-gated recorded PTY.
    static func runWorkflow(named name: String, at endpoint: URL) async throws {
        let fixture = try ReplayFixture.load(named: name)
        let clientID = fixture.events.compactMap(\.lifecycle).first?.clientId ?? "r5-" + name
        var size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)
        var palette = Terminal.Palette.default
        var connection = try TerminalWorker(baseURL: endpoint, clientID: clientID, size: size, palette: palette)
        guard try await connection.nextEvent() == .ready(resumed: false) else {
            throw CheckFailure("Expected a fresh attachment for \(name)")
        }
        var checked = 0, received = 0
        for event in fixture.events {
            if let lifecycle = event.lifecycle {
                switch lifecycle.type {
                case .detach:
                    await connection.detach()
                case .ready:
                    connection = try TerminalWorker(baseURL: endpoint, clientID: clientID, size: size, palette: palette)
                    guard try await connection.nextEvent() == .ready(resumed: lifecycle.resumed == true) else {
                        throw CheckFailure("Unexpected attachment at \(event.name)")
                    }
                }
            }
            if let nextPalette = event.palette {
                palette = nextPalette
                await connection.setPalette(palette, cursor: .white)
            }
            if let requested = event.resize {
                size = .init(columns: requested.columns, rows: requested.rows)
                try await connection.sendResize(to: size)
            }
            if let input = event.semanticInput { try await connection.send(input) }
            if !event.bytes.isEmpty {
                guard try await connection.nextEvent() == .output else {
                    throw CheckFailure("Expected PTY output at \(event.name)")
                }
                received += event.bytes.count
            }
            if event.checkpoint != nil {
                try event.verify(await connection.snapshot())
                checked += 1
            }
        }
        try await connection.closeShell()
        print("\(name) passed \(checked) socket checkpoints across \(received) recorded output bytes.")
    }
}
