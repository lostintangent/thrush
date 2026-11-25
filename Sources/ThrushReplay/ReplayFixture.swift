import CryptoKit
import Foundation
import Thrush

/// Development-only playback data and independent expected screens for the recorded workflows.
package struct ReplayFixture: Sendable {
    package static let names = ["shell-log", "vim-edit", "shell-edges", "prompt-bom", "vim-swift-dark", "vim-swift-light",
                                "hardware-keys", "shell-workflow", "vim-resume", "codex-session"]

    package struct Grid: Decodable, Sendable {
        package let columns: Int
        package let rows: Int
    }

    private struct RawPalette: Decodable {
        let foreground: String
        let background: String
        let ansi: [String]

        func palette() throws -> Terminal.Palette {
            guard ansi.count == 16 else { throw Failure("A fixture palette requires 16 ANSI colors.") }
            return try Terminal.Palette(foreground: Self.rgb(foreground), background: Self.rgb(background),
                                        ansi: ansi.map(Self.rgb))
        }

        private static func rgb(_ text: String) throws -> Terminal.RGB {
            let digits = text.dropFirst()
            guard text.first == "#", text.utf8.count == 7, digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(digits, radix: 16) else {
                throw Failure("Invalid fixture color \(text). Expected #rrggbb.")
            }
            return .init(red: UInt8(value >> 16), green: UInt8(truncatingIfNeeded: value >> 8),
                         blue: UInt8(truncatingIfNeeded: value))
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    fileprivate struct Action: Decodable, Sendable {
        enum Kind: String, Decodable { case text, paste, key }
        let kind: Kind
        let value: String
        let modifiers: [String]?

        func terminalInput() throws -> Terminal.Input {
            switch kind {
            case .text: return .text(value)
            case .paste: return .paste(value)
            case .key:
                let named: [String: Terminal.Input.Key] = [
                    "up": .up, "down": .down, "left": .left, "right": .right, "home": .home, "end": .end,
                    "pageUp": .pageUp, "pageDown": .pageDown, "delete": .delete, "enter": .enter,
                    "escape": .escape, "backspace": .backspace, "tab": .tab,
                ]
                guard let key = named[value] ?? (value.count == 1 ? value.first.map { .character($0) } : nil)
                else { throw Failure("Unknown recorded key \(value)") }
                var flags: Terminal.Input.Modifiers = []
                for modifier in modifiers ?? [] {
                    switch modifier {
                    case "shift": flags.insert(.shift)
                    case "alt": flags.insert(.alt)
                    case "control": flags.insert(.control)
                    default: throw Failure("Unknown recorded modifier \(modifier)")
                    }
                }
                return .key(key, modifiers: flags)
            }
        }
    }

    private struct RawCell: Decodable {
        let text: String
        let width: Int
        let flags: UInt8
        let foreground: Int
        let background: Int

        func style() -> Terminal.Style {
            var s = Terminal.Style()
            s.foreground = Self.color(foreground)
            s.background = Self.color(background)
            s.bold = flags & 1 != 0
            s.dim = flags & 2 != 0
            s.italic = flags & 4 != 0
            s.underline = flags & 8 != 0
            s.blink = flags & 16 != 0
            s.inverse = flags & 32 != 0
            s.invisible = flags & 64 != 0
            s.strikethrough = flags & 128 != 0
            return s
        }

        static func color(_ code: Int) -> Terminal.Color {
            if code < 0 { return .default }
            if code < 256 { return .indexed(UInt8(code)) }
            let rgb = code - 256
            return .rgb(UInt8(rgb >> 16), UInt8(truncatingIfNeeded: rgb >> 8), UInt8(truncatingIfNeeded: rgb))
        }
    }

    fileprivate struct Cell: Sendable {
        let text: String
        let width: Int
        let style: Terminal.Style

        func matches(_ cell: Terminal.Cell) -> Bool {
            width == cell.width && style == cell.style && text.utf8.elementsEqual(cell.text.utf8)
        }
    }

    fileprivate struct Line: Decodable, Sendable {
        let wrapped: Bool
        let text: String
        // Pairs of repetition count and cell index. The omitted tail consists of blank cells.
        let runs: [Int]
    }

    fileprivate struct Pool: Sendable {
        let cells: [Cell]
        let lines: [Line]
    }

    package struct Checkpoint: Decodable, Sendable {
        fileprivate struct Modes: Decodable, Equatable, Sendable {
            let applicationCursorKeys, applicationKeypad, bracketedPaste, insert, origin, wraparound, cursorVisible, cursorBlink, sendFocus: Bool
        }
        package let columns: Int
        package let rows: Int
        package let cursorColumn: Int
        package let cursorRow: Int
        fileprivate let cursorShape: String
        fileprivate let cursorBlink: Bool
        fileprivate let synchronizedOutput: Bool?
        package let isAlternate: Bool
        package let history: [Int]
        package let visible: [Int]
        fileprivate let modes: Modes
    }

    package struct Lifecycle: Decodable, Sendable {
        package enum Kind: String, Decodable, Sendable { case detach, ready }
        package let type: Kind
        package let clientId: String
        package let resumed: Bool?
    }

    package struct Copy: Decodable, Sendable {
        package struct Position: Decodable, Sendable {
            package let row: Int
            package let column: Int
        }

        package let start: Position
        package let end: Position
        package let text: String
    }

    private struct RawEvent: Decodable {
        let name: String
        let offsetMicroseconds: Int
        let bytes: Data?
        let input: Data?
        let reply: Data?
        let resize: Grid?
        let palette: RawPalette?
        let lifecycle: Lifecycle?
        let copy: Copy?
        let normalHistoryRowsBefore, historyRowsBefore: Int?
        let action: Action?
        let checkpoint: Checkpoint?
    }

    private struct Recording: Decodable {
        let name: String
        let version: Int
        let columns: Int
        let rows: Int
        let cells: [RawCell]
        let lines: [Line]
        let events: [RawEvent]
    }

    package struct Event: Sendable {
        package let name: String
        package let offsetMicroseconds: Int
        package let bytes: [UInt8]
        package let input: [UInt8]
        package let reply: [UInt8]
        package let resize: Grid?
        package let palette: Terminal.Palette?
        package let lifecycle: Lifecycle?
        package let copy: Copy?
        package var hasSemanticInput: Bool { semanticInput != nil }
        package let normalHistoryRowsBefore, historyRowsBefore: Int?
        package let checkpoint: Checkpoint?
        package let semanticInput: Terminal.Input?
        fileprivate let pool: Pool

        /// A ready control precedes any serialized replay on the new attachment.
        package func applyReady(to terminal: inout Terminal) {
            if lifecycle?.type == .ready { terminal = Terminal(size: terminal.size, palette: terminal.palette) }
        }

        package func encodedInput(using terminal: Terminal) -> [UInt8]? {
            semanticInput.map { terminal.encode($0) }
        }

        package func verify(_ terminal: Terminal) throws {
            if let encoded = encodedInput(using: terminal), encoded != input {
                throw Failure("\(name) input: got \(encoded), expected \(input)")
            }
            if checkpoint != nil { try verify(terminal.snapshot()) }
        }

        package func verify(_ snapshot: Terminal.Snapshot) throws {
            guard let checkpoint else { return }
            let modes = snapshot.modes
            if let expected = checkpoint.synchronizedOutput, (snapshot.synchronizedOutputID != nil) != expected {
                throw Failure("\(name) synchronized output should be \(expected)")
            }
            let actualModes = Checkpoint.Modes(applicationCursorKeys: modes.applicationCursorKeys,
                applicationKeypad: modes.applicationKeypad, bracketedPaste: modes.bracketedPaste,
                insert: modes.insert, origin: modes.origin, wraparound: modes.wraparound,
                cursorVisible: modes.cursorVisible, cursorBlink: modes.cursorBlink, sendFocus: modes.sendFocus)
            guard actualModes == checkpoint.modes, snapshot.cursorVisible == checkpoint.modes.cursorVisible else {
                throw Failure("\(name) modes: got \(actualModes), expected \(checkpoint.modes)")
            }
            guard snapshot.cursorShape.rawValue == checkpoint.cursorShape, snapshot.cursorBlink == checkpoint.cursorBlink else {
                throw Failure("\(name) cursor style: got \(snapshot.cursorShape) blink \(snapshot.cursorBlink), expected \(checkpoint.cursorShape) blink \(checkpoint.cursorBlink)")
            }
            guard snapshot.size.columns == checkpoint.columns, snapshot.size.rows == checkpoint.rows else {
                throw Failure("\(name) size: got \(snapshot.size), expected \(checkpoint.columns)×\(checkpoint.rows)")
            }
            guard snapshot.isAlternate == checkpoint.isAlternate,
                  snapshot.cursorRow == checkpoint.cursorRow, snapshot.cursorColumn == checkpoint.cursorColumn else {
                throw Failure("\(name) alternate/cursor: got \(snapshot.isAlternate) \(snapshot.cursorRow),\(snapshot.cursorColumn), expected \(checkpoint.isAlternate) \(checkpoint.cursorRow),\(checkpoint.cursorColumn)")
            }
            try verifyRows(snapshot.history, expected: checkpoint.history, columns: checkpoint.columns, group: "history")
            try verifyRows(snapshot.rows, expected: checkpoint.visible, columns: checkpoint.columns, group: "viewport")
        }

        private func verifyRows<Rows: Collection>(_ actual: Rows, expected: [Int], columns: Int, group: String) throws
        where Rows.Element == Terminal.Row {
            guard actual.count == expected.count else {
                throw Failure("\(name) \(group) count: got \(actual.count), expected \(expected.count)")
            }
            for (index, row) in actual.enumerated() {
                let line = pool.lines[expected[index]]
                guard row.text.utf8.elementsEqual(line.text.utf8) else {
                    throw Failure("\(name) \(group) row \(index): got \(row.text.debugDescription), expected \(line.text.debugDescription)")
                }
                guard row.isWrapped == line.wrapped else {
                    throw Failure("\(name) \(group) row \(index) wrap: got \(row.isWrapped), expected \(line.wrapped), text \(row.text.debugDescription)")
                }
                var column = 0
                for pair in stride(from: 0, to: line.runs.count, by: 2) {
                    let cell = pool.cells[line.runs[pair + 1]]
                    guard line.runs[pair] <= columns - column else {
                        throw Failure("\(name) \(group) row \(index) exceeds \(columns) columns")
                    }
                    let end = column + line.runs[pair]
                    for x in column..<end where !cell.matches(row[x]) {
                        throw mismatch(group, index, x, row[x], cell)
                    }
                    column = end
                }
                let blank = pool.cells[0]
                for x in column..<columns where !blank.matches(row[x]) {
                    throw mismatch(group, index, x, row[x], blank)
                }
            }
        }

        private func mismatch(_ group: String, _ y: Int, _ x: Int, _ actual: Terminal.Cell, _ expected: Cell) -> Failure {
            Failure("\(name) \(group) [\(y),\(x)]: got \(actual), expected \(expected)")
        }
    }

    package let name: String
    package let columns: Int
    package let rows: Int
    package let events: [Event]
    package let sha256: String

    package static func decode(_ data: Data) throws -> Self {
        let recording = try JSONDecoder().decode(Recording.self, from: data)
        guard recording.version == 1 else { throw Failure("Unsupported replay version \(recording.version)") }
        guard recording.columns > 0, recording.rows > 0, !recording.cells.isEmpty else {
            throw Failure("Missing terminal grid or reference cells")
        }
        for cell in recording.cells {
            guard (0...2).contains(cell.width), (-1...0x10000FF).contains(cell.foreground),
                  (-1...0x10000FF).contains(cell.background) else { throw Failure("Invalid reference cell") }
        }
        for line in recording.lines {
            guard line.runs.count.isMultiple(of: 2) else { throw Failure("Incomplete reference cell run") }
            for i in stride(from: 0, to: line.runs.count, by: 2) {
                guard line.runs[i] > 0, recording.cells.indices.contains(line.runs[i + 1]) else {
                    throw Failure("Invalid reference cell run")
                }
            }
        }
        let pool = Pool(cells: recording.cells.map { Cell(text: $0.text, width: $0.width, style: $0.style()) },
                        lines: recording.lines)
        let events = try recording.events.map { event in
            if let check = event.checkpoint {
                guard check.columns > 0, check.visible.count == check.rows,
                      check.visible.allSatisfy(recording.lines.indices.contains),
                      check.history.allSatisfy(recording.lines.indices.contains) else {
                    throw Failure("Invalid reference rows in \(event.name)")
                }
            }
            return Event(name: event.name, offsetMicroseconds: event.offsetMicroseconds,
                  bytes: Array(event.bytes ?? Data()), input: Array(event.input ?? Data()),
                  reply: Array(event.reply ?? Data()), resize: event.resize, palette: try event.palette?.palette(),
                  lifecycle: event.lifecycle, copy: event.copy,
                  normalHistoryRowsBefore: event.normalHistoryRowsBefore, historyRowsBefore: event.historyRowsBefore,
                  checkpoint: event.checkpoint,
                  semanticInput: try event.action?.terminalInput(), pool: pool)
        }
        return Self(name: recording.name, columns: recording.columns, rows: recording.rows, events: events,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
