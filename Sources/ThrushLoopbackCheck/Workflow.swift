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
        var session = try SessionActor(baseURL: endpoint, clientID: clientID, size: size, palette: palette)
        guard try await session.nextEvent() == .ready(resumed: false) else {
            throw CheckFailure("Expected a fresh attachment for \(name)")
        }
        var expectedOutput = SessionActor.Event.output
        var checked = 0, received = 0
        for event in fixture.events {
            if let lifecycle = event.lifecycle {
                switch lifecycle.type {
                case .detach:
                    await session.hide()
                case .ready:
                    session = try SessionActor(baseURL: endpoint, clientID: clientID, size: size, palette: palette)
                    let resumed = lifecycle.resumed == true
                    expectedOutput = resumed ? .replay : .output
                    guard try await session.nextEvent() == .ready(resumed: resumed) else {
                        throw CheckFailure("Unexpected attachment at \(event.name)")
                    }
                }
            }
            if let nextPalette = event.palette {
                palette = nextPalette
                await session.setPalette(palette, cursor: .white)
            }
            if let requested = event.resize {
                size = .init(columns: requested.columns, rows: requested.rows)
                try await session.sendResize(to: size)
            }
            if let input = event.semanticInput { try await session.send(input) }
            if !event.bytes.isEmpty {
                guard try await session.nextEvent() == expectedOutput else {
                    throw CheckFailure("Expected \(expectedOutput) at \(event.name)")
                }
                expectedOutput = .output
                received += event.bytes.count
            }
            if event.checkpoint != nil {
                try event.verify(await session.snapshot())
                checked += 1
            }
        }
        guard expectedOutput == .output else { throw CheckFailure("The recorded workflow ended before its replay") }
        try await session.closeShell()
        print("\(name) passed \(checked) socket checkpoints across \(received) recorded output bytes.")
    }
}
