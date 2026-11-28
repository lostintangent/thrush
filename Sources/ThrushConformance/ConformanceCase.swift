import Foundation
import ThrushCore
import ThrushFixtures

/// Bytes fed to a fresh terminal, with the checkpoints the reference emulator reached on the same bytes.
///
/// `Fixtures/reference/conformance/harness.mjs` writes these cases from the function corpus,
/// recorded programs and seeded random streams. Thrush never produces its own expectations.
struct ConformanceCase: Decodable, Sendable {
    enum Step: Sendable {
        case write([UInt8])
        case resize(Terminal.Size)
        /// Gives or takes keyboard focus, as the host would.
        case focus(Bool)
        /// Records a checkpoint. A visible-only checkpoint skips history and the inactive normal screen.
        case checkpoint(String, includesHistory: Bool)
    }

    struct Colors: Decodable, Sendable {
        var foreground: String
        var background: String
        var ansi: [String]
    }

    /// A readable identity such as `DCH 1 · at the last column`.
    var name: String
    /// The control function the case exercises, or the program or stream it came from.
    var subject: String
    var size: [Int]
    var palette: Colors?
    var steps: [Step]
    /// The reference's checkpoints, in step order, ending with `end`.
    var expected: [Checkpoint]?

    /// Replays the steps through ThrushCore and records the same checkpoints the reference recorded.
    /// A frame can draw after any step, so each step also draws the screen the way the renderer does.
    func run() -> [Checkpoint] {
        var terminal = Terminal(size: Terminal.Size(columns: size[0], rows: size[1]), palette: thrushPalette)
        var replies: [UInt8] = []
        var drawing = Drawing()
        var checkpoints: [Checkpoint] = []
        for step in steps {
            if case .checkpoint(let name, let includesHistory) = step {
                var checkpoint = Checkpoint(terminal, name: name, includesHistory: includesHistory, replies: replies)
                checkpoint.misdrawn = drawing.misdrawn
                checkpoints.append(checkpoint)
                drawing.misdrawn = nil
                replies = []
                continue
            }
            replies += terminal.perform(step)
            drawing.draw(terminal.snapshot())
        }
        return checkpoints
    }

    /// The renderer draws a row once per generation and reuses that drawing while the size and buffer
    /// stay the same, so each generation has to name one row's cells.
    private struct Drawing {
        private var rows: [UInt64: [Terminal.Cell]] = [:]
        private var base: (size: Terminal.Size, isAlternate: Bool)?
        /// The first cell since the previous checkpoint that shows a drawing of other cells.
        var misdrawn: Checkpoint.Misdrawn?

        mutating func draw(_ snapshot: Terminal.Snapshot) {
            if base?.size != snapshot.size || base?.isAlternate != snapshot.isAlternate {
                rows = [:]
                base = (snapshot.size, snapshot.isAlternate)
            }
            for (index, row) in snapshot.rows.enumerated() {
                let cells = (0..<snapshot.size.columns).map { row[$0] }
                guard let drawn = rows[row.generation] else {
                    rows[row.generation] = cells
                    continue
                }
                guard misdrawn == nil, let column = cells.indices.first(where: { cells[$0] != drawn[$0] }) else { continue }
                misdrawn = Checkpoint.Misdrawn(row: index, column: column, holds: Checkpoint.Cell(cells[column]),
                                               shows: Checkpoint.Cell(drawn[column]))
            }
        }
    }

    var input: [UInt8] {
        steps.flatMap { step -> [UInt8] in
            if case .write(let bytes) = step { bytes } else { [] }
        }
    }

    var thrushPalette: Terminal.Palette {
        guard let palette else { return .default }
        func rgb(_ text: String) -> Terminal.RGB {
            let value = UInt32(text.dropFirst(), radix: 16) ?? 0
            return Terminal.RGB(red: UInt8(value >> 16), green: UInt8(truncatingIfNeeded: value >> 8),
                                blue: UInt8(truncatingIfNeeded: value))
        }
        return Terminal.Palette(foreground: rgb(palette.foreground), background: rgb(palette.background),
                                ansi: palette.ansi.map(rgb))
    }
}

extension Terminal {
    /// Performs a step as the host would and returns the replies. A checkpoint performs nothing.
    mutating func perform(_ step: ConformanceCase.Step) -> [UInt8] {
        switch step {
        case .write(let bytes):
            return write(bytes)
        case .resize(let size):
            resize(to: size)
        case .focus(let focused) where focused != isFocused:
            isFocused = focused
            return encode(.focus(focused))
        case .focus, .checkpoint:
            break
        }
        return []
    }
}

extension ConformanceCase.Step: Decodable {
    private enum CodingKeys: String, CodingKey { case write, resize, focus, checkpoint, scope }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let write = try container.decodeIfPresent(String.self, forKey: .write) {
            guard let bytes = Data(base64Encoded: write) else {
                throw DecodingError.dataCorruptedError(forKey: .write, in: container, debugDescription: "Writes are base64")
            }
            self = .write([UInt8](bytes))
        } else if let size = try container.decodeIfPresent([Int].self, forKey: .resize) {
            self = .resize(Terminal.Size(columns: size[0], rows: size[1]))
        } else if let focused = try container.decodeIfPresent(Bool.self, forKey: .focus) {
            self = .focus(focused)
        } else {
            let scope = try container.decodeIfPresent(String.self, forKey: .scope)
            self = .checkpoint(try container.decode(String.self, forKey: .checkpoint), includesHistory: scope != "visible")
        }
    }
}

extension ConformanceCase {
    /// Loads a generated case file, whose checkpoints name lines by index into shared pools.
    static func load(contentsOf url: URL) throws -> [ConformanceCase] {
        struct File: Decodable { var cases: [ConformanceCase] }
        let data = try Data(contentsOf: url)
        return try LinePool(decoding: data).decoder.decode(File.self, from: data).cases
    }
}

extension ConformanceCase {
    /// The differences from the reference across every checkpoint, or none when Thrush matches.
    func differences(in actual: [Checkpoint]) -> [Difference] {
        guard let expected else { return [] }
        if actual.count != expected.count {
            return [Difference(checkpoint: "end", path: "checkpoints", reference: "\(expected.count)", thrush: "\(actual.count)")]
        }
        return zip(expected, actual).flatMap { $1.differences(from: $0) }
    }

    /// A readable account of the first checkpoint that differs, with both grids side by side.
    func report(_ actual: [Checkpoint]) -> String? {
        let differences = differences(in: actual)
        guard let first = differences.first, let expected,
              let reference = expected.first(where: { $0.name == first.checkpoint }),
              let thrush = actual.first(where: { $0.name == first.checkpoint }) else { return nil }
        let input = Checkpoint.printable(self.input)
        var lines = [
            "\(name) differs from the reference at checkpoint \"\(first.checkpoint)\".",
            "Input: \(input.count > 400 ? input.prefix(400) + "…" : input[...])",
            "",
        ]
        lines += differences.filter { $0.checkpoint == first.checkpoint }.prefix(12).map { "  \($0)" }
        // Grid rows are exactly one display column per cell, so the two grids line up.
        let blank = String(repeating: " ", count: reference.size[0])
        let header = "Reference" + String(repeating: " ", count: max(0, reference.size[0] - 9))
        lines += ["", "      \(header)    Thrush"]
        for row in 0..<max(reference.grid.count, thrush.grid.count) {
            let left = reference.grid[safe: row] ?? blank, right = thrush.grid[safe: row] ?? ""
            let marker = reference.active.visible[safe: row] == thrush.active.visible[safe: row] ? " " : "≠"
            lines.append("  \(String(row).leftPadded(to: 2)) │\(left)│ \(marker) │\(right)│")
        }
        lines.append("  cursor: reference row \(reference.cursor.row), column \(reference.cursor.column) · "
                     + "Thrush row \(thrush.cursor.row), column \(thrush.cursor.column)")
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension String {
    func leftPadded(to width: Int) -> String { String(repeating: " ", count: max(0, width - count)) + self }
}
