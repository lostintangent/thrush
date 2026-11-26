import Dispatch
import ThrushCore
import ThrushFixtures

struct ShellTransitions: Encodable {
    struct Measurement: Encodable {
        let historyRowsBefore: Int
        let historyRowsAfter: Int
        let timing: Timing
    }

    private static let promptText = "thrush$ "

    let grid: BenchmarkGrid
    let measuredPasses: Int
    let promptFixtureSHA256: String
    let startNewShell: Measurement
    let prepareForReplay: Measurement

    static func measure() throws -> Self {
        let grid = BenchmarkGrid.desktop
        let fixture = try Recording.load(named: "shell-workflow")
        guard let prompt = fixture.events.first, prompt.name == "Shell prompt" else {
            throw BenchmarkError("Missing shell-workflow PTY prompt.")
        }

        let oldLines = (1...1_016).map { "previous shell output \($0)" }
        let currentLines = (1...31).map { "current shell output \($0)" }
        let oldOutput = Array((oldLines.joined(separator: "\r\n") + "\u{1b}[?25l").utf8)
        let currentOutput = Array(("\r\n" + currentLines.joined(separator: "\r\n") + "\u{1b}[?25l").utf8)
        let retained = oldLines.suffix(1_000)
        let retainedForReplay = retained.dropFirst(8)
        let mixedHistory = Array(retainedForReplay) + [promptText] + currentLines.prefix(7)
        let measured = 25
        var startTimes: [UInt64] = []
        var replayTimes: [UInt64] = []

        for pass in 0...measured {
            var terminal = Terminal(size: grid.size)
            guard terminal.receive(oldOutput).isEmpty, terminal.snapshot().history.count == 992 else {
                throw BenchmarkError("Previous shell requires 992 history rows and 24 occupied screen rows.")
            }

            let start = DispatchTime.now().uptimeNanoseconds
            terminal.startNewShell(at: grid.size)
            let startTime = DispatchTime.now().uptimeNanoseconds - start
            try verifyFreshShell(&terminal, history: retained, prompt: prompt)

            guard terminal.receive(currentOutput).isEmpty,
                  terminal.snapshot().history.lazy.map(\.text).elementsEqual(mixedHistory) else {
                throw BenchmarkError("Expected 992 archived rows followed by eight current-shell rows before replay.")
            }

            let replay = DispatchTime.now().uptimeNanoseconds
            terminal.prepareForReplay(at: grid.size)
            let replayTime = DispatchTime.now().uptimeNanoseconds - replay
            try verifyFreshShell(&terminal, history: retainedForReplay, prompt: prompt)
            if pass > 0 {
                startTimes.append(startTime)
                replayTimes.append(replayTime)
            }
        }
        return Self(grid: grid, measuredPasses: measured, promptFixtureSHA256: fixture.sha256,
                    startNewShell: .init(historyRowsBefore: 992, historyRowsAfter: retained.count, timing: Timing(startTimes)),
                    prepareForReplay: .init(historyRowsBefore: mixedHistory.count, historyRowsAfter: retainedForReplay.count,
                                            timing: Timing(replayTimes)))
    }

    private static func verifyFreshShell(_ terminal: inout Terminal, history: ArraySlice<String>,
                                         prompt: Recording.Event) throws {
        let fresh = terminal.snapshot()
        guard fresh.history.lazy.map(\.text).elementsEqual(history) else {
            throw BenchmarkError("Expected \(history.count) archived rows in their original order.")
        }
        guard !fresh.isAlternate, fresh.cursorRow == 0, fresh.cursorColumn == 0, fresh.cursorVisible,
              !fresh.modes.bracketedPaste, fresh.rows.allSatisfy({ $0.text.isEmpty }) else {
            throw BenchmarkError("Shell transition did not restore a fresh screen, cursor and input modes.")
        }
        guard terminal.receive(prompt.bytes) == prompt.reply else { throw BenchmarkError("Unexpected shell prompt reply.") }
        let drawn = terminal.snapshot()
        guard drawn.rows[0].text == promptText, drawn.rows.dropFirst().allSatisfy({ $0.text.isEmpty }),
              drawn.cursorRow == 0, drawn.cursorColumn == promptText.utf8.count, drawn.modes.bracketedPaste, drawn.history.count == history.count else {
            throw BenchmarkError("Recorded shell prompt or its bracketed-paste mode failed after a shell transition.")
        }
    }
}
