import Foundation
import Thrush
import ThrushFixtures

/// Drives the same attachment, input and row access that an app uses.
@main
struct WebSocketCheck {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().elementsEqual(["--benchmark"]) {
            #if DEBUG
            throw CheckFailure("Time the lifecycle from a Release build: swift run -c release ThrushWebSocketCheck --benchmark")
            #else
            try benchmarkLifecycle()
            return
            #endif
        }
        if arguments.count == 4, arguments[1] == "--workflow", let endpoint = URL(string: arguments[3]) {
            try await runWorkflow(named: arguments[2], at: endpoint)
            return
        }
        if arguments.count == 3, arguments[1] == "--lifecycle", let endpoint = URL(string: arguments[2]) {
            try await LifecycleCheck(endpoint: endpoint).run()
            try await ReconnectCheck(endpoint: endpoint).run()
            try await InBandReplayCheck(endpoint: endpoint).run()
            return
        }
        if arguments.count == 6, arguments[1] == "--pty", let endpoint = URL(string: arguments[2]) {
            let directory = URL(filePath: arguments[5], directoryHint: .isDirectory)
            try await checkPTY(at: endpoint, token: arguments[3], scenario: arguments[4], directory: directory)
            return
        }
        guard arguments.count == 2, let endpoint = URL(string: arguments[1]) else {
            throw CheckFailure("Usage: ThrushWebSocketCheck [--lifecycle | --workflow NAME] SERVER_BASE_URL, ThrushWebSocketCheck --pty SERVER_BASE_URL TOKEN SCENARIO DIRECTORY or ThrushWebSocketCheck --benchmark")
        }

        let fixture = try FirstBytesFixture.load()
        let size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)
        // A plus and a space round-trip distinctly through the real server's URLSearchParams.
        let clientID = "thrush + check"
        let session = SessionActor(size: size, makeSocket: terminalSocket(at: endpoint, clientID: clientID))
        guard try await session.nextEvent() == .ready(resumed: false) else {
            throw CheckFailure("Expected fresh ready before output")
        }
        for (index, event) in fixture.events.enumerated() {
            guard try await session.nextEvent() == .output else {
                throw CheckFailure("Expected binary output at chunk \(index)")
            }
            let row = await session.text(inRow: event.row)
            guard row == event.text else {
                throw CheckFailure("Unexpected row at chunk \(index): \(row.debugDescription)")
            }
            if event.up != nil { try await session.send(.key(.up)) }
        }
        try await session.sendResize(to: .init(columns: size.columns + 1, rows: size.rows + 1))
        guard try await session.nextEvent() == .ended,
              let final = fixture.events.last, await session.text(inRow: final.row) == final.text
        else { throw CheckFailure("Expected the last output to remain readable at exit") }

        // A one-column request needs two columns in the attach URL and every resize.
        let minimum = Terminal.Size(columns: 1, rows: 2)
        let defaults = Terminal.Palette.default
        let light = Terminal.Palette(foreground: defaults.background, background: defaults.foreground, ansi: defaults.ansi)
        let next = SessionActor(size: minimum, palette: light, makeSocket: terminalSocket(at: endpoint, clientID: clientID))
        guard try await next.nextEvent() == .ready(resumed: false), await next.text(inRow: 0).isEmpty,
              try await next.nextEvent() == .output, await next.text(inRow: 0) == "AB",
              await next.text(inRow: 1).isEmpty
        else { throw CheckFailure("Expected AB on row zero of the fresh two-column grid") }
        let beforeSwitch = await next.snapshot()
        await next.setPalette(defaults, cursor: .white)
        let afterSwitch = await next.snapshot()
        guard beforeSwitch.palette == light, afterSwitch.palette == defaults,
              beforeSwitch.generation != afterSwitch.generation,
              beforeSwitch.rows.map(\.generation) == afterSwitch.rows.map(\.generation),
              afterSwitch.rows[0].text == "AB", afterSwitch.cursorColumn == beforeSwitch.cursorColumn
        else { throw CheckFailure("Changing the host palette must preserve the grid and cursor") }
        try await next.sendResize(to: .init(columns: 5, rows: 3))
        try await next.sendResize(to: minimum)
        try await next.sendResize(to: .init(columns: 2, rows: 2))
        guard try await next.nextEvent() == .output, await next.text(inRow: 0) == "XY",
              await next.text(inRow: 1) == "Z"
        else { throw CheckFailure("The peer and the resized terminal must share a two-column grid") }
        try await next.closeShell()
    }
}
