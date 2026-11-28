import Foundation
import ThrushCore

/// Everything a program can observe about a terminal at one point in a conformance case or recording.
///
/// The reference emulator and ThrushCore both report this shape, so a checkpoint passes when the two are equal.
/// The tooling in `Fixtures/reference/conformance` reads the same fields from the reference.
package struct Checkpoint: Decodable, Equatable, Sendable {
    package struct Cursor: Decodable, Equatable, Sendable {
        package var row: Int
        package var column: Int
        package var visible: Bool
        package var shape: String
        package var blink: Bool
    }

    package struct Modes: Decodable, Equatable, Sendable {
        package var applicationCursorKeys: Bool
        package var applicationKeypad: Bool
        package var bracketedPaste: Bool
        package var insert: Bool
        package var origin: Bool
        package var wraparound: Bool
        package var reverseWraparound: Bool
        package var cursorBlink: Bool
        package var sendFocus: Bool
        package var synchronizedOutput: Bool
        package var mouseTracking: String
        package var mouseEncoding: String
    }

    /// One grid cell. Styles are space-separated attributes such as `fg=1 bold`, or empty for the default.
    /// `link=n` names the checkpoint's `n`th link.
    package struct Cell: Decodable, Hashable, Sendable {
        package static let blank = Cell(text: "", width: 1, style: "")

        package var text: String
        package var width: Int
        package var style: String

        package init(text: String, width: Int, style: String) {
            self.text = text
            self.width = width
            self.style = style
        }

        package init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.init(text: try container.decode(String.self), width: try container.decode(Int.self),
                      style: try container.decode(String.self))
        }
    }

    /// A row without its trailing blank cells. `wrapped` means it continues the row above.
    package struct Line: Decodable, Hashable, Sendable {
        package var wrapped: Bool
        package var cells: [Cell]

        private enum CodingKeys: CodingKey { case wrapped, cells }

        package subscript(column: Int) -> Cell { column < cells.count ? cells[column] : .blank }

        package init(wrapped: Bool, cells: [Cell]) {
            self.wrapped = wrapped
            self.cells = cells
        }

        /// Generated files name each line by its index in a shared pool.
        package init(from decoder: any Decoder) throws {
            if let pool = decoder.userInfo[.linePool] as? LinePool {
                let container = try decoder.singleValueContainer()
                let index = try container.decode(Int.self)
                guard pool.lines.indices.contains(index) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "No pooled line \(index)")
                }
                self = pool.lines[index]
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wrapped = try container.decode(Bool.self, forKey: .wrapped)
            cells = try container.decode([Cell].self, forKey: .cells)
        }
    }

    package struct Screen: Decodable, Equatable, Sendable {
        /// Scrolled-off rows, oldest first. Absent when the checkpoint only records the visible grid.
        package var history: [Line]?
        package var visible: [Line]
    }

    package var name: String
    package var size: [Int]
    package var cursor: Cursor
    package var buffer: String
    package var modes: Modes
    package var title: String
    /// The bytes the terminal sent back since the previous checkpoint, one character per byte.
    /// Absent in recordings, whose events carry their own replies.
    package var replies: String?
    package var active: Screen
    /// The normal screen while the alternate screen is active, as the user returns to it.
    package var normal: Screen?
    /// Each link's id and URI as `id;uri`, numbered from 1 in the order the screens above show them.
    /// Absent without links.
    package var links: [String]?
    /// What the reference threw while processing the writes before this checkpoint. Thrush never sets it.
    package var error: String?
    /// The first cell since the previous checkpoint that Thrush's renderer would draw as another cell,
    /// because its row kept a generation that named other cells. The reference never sets it.
    package var misdrawn: Misdrawn?

    package struct Misdrawn: Decodable, Equatable, Sendable {
        package var row: Int
        package var column: Int
        package var holds: Cell
        package var shows: Cell

        package init(row: Int, column: Int, holds: Cell, shows: Cell) {
            self.row = row
            self.column = column
            self.holds = holds
            self.shows = shows
        }
    }
}

extension Checkpoint {
    package init(_ terminal: Terminal, name: String, includesHistory: Bool, replies: [UInt8]? = nil) {
        let snapshot = terminal.snapshot()
        var normal: Terminal.Snapshot?
        if snapshot.isAlternate && includesHistory {
            // Leaving the alternate screen on a copy reveals the normal screen as the user returns to it.
            var copy = terminal
            _ = copy.write(Array("\u{1b}[?1049l".utf8))
            normal = copy.snapshot()
        }
        self.init(snapshot, name: name, includesHistory: includesHistory, title: terminal.title, normal: normal)
        self.replies = replies.map { String(String.UnicodeScalarView($0.map(Unicode.Scalar.init))) }
    }

    /// What a snapshot shows. It holds neither the title nor the normal screen behind the alternate one,
    /// so a terminal supplies those.
    package init(_ snapshot: Terminal.Snapshot, name: String, includesHistory: Bool, title: String = "",
                 normal: Terminal.Snapshot? = nil) {
        let modes = snapshot.modes
        self.name = name
        size = [snapshot.size.columns, snapshot.size.rows]
        cursor = Cursor(row: snapshot.cursorRow, column: snapshot.cursorColumn, visible: snapshot.cursorVisible,
                        shape: snapshot.cursorShape.rawValue, blink: snapshot.cursorBlink)
        buffer = snapshot.isAlternate ? "alternate" : "normal"
        self.modes = Modes(
            applicationCursorKeys: modes.applicationCursorKeys, applicationKeypad: modes.applicationKeypad,
            bracketedPaste: modes.bracketedPaste, insert: modes.insert, origin: modes.origin,
            wraparound: modes.wraparound, reverseWraparound: modes.reverseWraparound, cursorBlink: modes.cursorBlink,
            sendFocus: modes.sendFocus, synchronizedOutput: modes.synchronizedOutput,
            mouseTracking: "\(modes.mouseTracking)", mouseEncoding: modes.mouseSGR ? "sgr" : "default")
        self.title = title
        var styles = Styles()
        active = Screen(snapshot, includesHistory: includesHistory, styles: &styles)
        self.normal = normal.map { Screen($0, includesHistory: true, styles: &styles) }
        links = styles.links.isEmpty ? nil : styles.links
    }

    /// Names styles as checkpoints write them. Links are numbered in the order they first appear, so
    /// checkpoints agree whatever numbers each emulator uses inside.
    struct Styles {
        private var names: [Terminal.Style: String] = [:]
        // Neighboring cells mostly share a style, so the last one named is checked first.
        private var last = (style: Terminal.Style(), name: "")
        private var numbers: [UInt32: Int] = [:]
        private(set) var links: [String] = []

        mutating func name(of style: Terminal.Style, in snapshot: Terminal.Snapshot) -> String {
            if style == last.style { return last.name }
            if let name = names[style] {
                last = (style, name)
            } else {
                last = (style, Checkpoint.style(style, link: number(of: style, in: snapshot)))
                names[style] = last.name
            }
            return last.name
        }

        private mutating func number(of style: Terminal.Style, in snapshot: Terminal.Snapshot) -> Int? {
            guard let link = snapshot.link(for: style) else { return nil }
            if let number = numbers[style.link] { return number }
            links.append("\(link.id ?? "");\(link.uri)")
            numbers[style.link] = links.count
            return links.count
        }
    }
}

extension Checkpoint.Screen {
    init(_ snapshot: Terminal.Snapshot, includesHistory: Bool, styles: inout Checkpoint.Styles) {
        history = includesHistory ? snapshot.history.map { Checkpoint.Line($0, in: snapshot, styles: &styles) } : nil
        visible = snapshot.rows.map { Checkpoint.Line($0, in: snapshot, styles: &styles) }
    }
}

extension Checkpoint.Line {
    init(_ row: Terminal.Row, in snapshot: Terminal.Snapshot, styles: inout Checkpoint.Styles) {
        wrapped = row.isWrapped
        cells = (0..<snapshot.size.columns).map { column in
            let cell = row[column]
            return Checkpoint.Cell(text: cell.text, width: cell.width, style: styles.name(of: cell.style, in: snapshot))
        }
        while cells.last == .blank { cells.removeLast() }
    }
}

extension Checkpoint.Cell {
    package init(_ cell: Terminal.Cell) {
        self.init(text: cell.text, width: cell.width, style: Checkpoint.style(cell.style))
    }
}

extension Checkpoint {
    /// The attributes in the order the reference's tooling lists them. The underline color is listed
    /// only with an underline, since it shows only then.
    static func style(_ style: Terminal.Style, link: Int? = nil) -> String {
        func color(_ color: Terminal.Color, _ kind: String) -> String? {
            switch color {
            case .default: nil
            case .indexed(let index): "\(kind)=\(index)"
            case .rgb(let red, let green, let blue): "\(kind)=#" + [red, green, blue].map(hex).joined()
            }
        }
        let underline: [String?] = switch style.underline {
        case .none: []
        case .single: ["underline", color(style.underlineColor, "underlineColor")]
        default: ["underline=\(style.underline.rawValue)", color(style.underlineColor, "underlineColor")]
        }
        let attributes: [String?] = [
            color(style.foreground, "fg"), color(style.background, "bg"), style.bold ? "bold" : nil,
            style.dim ? "dim" : nil, style.italic ? "italic" : nil,
        ] + underline + [
            style.blink ? "blink" : nil, style.inverse ? "inverse" : nil, style.invisible ? "invisible" : nil,
            style.strikethrough ? "strikethrough" : nil, style.overline ? "overline" : nil, link.map { "link=\($0)" },
        ]
        return attributes.compactMap(\.self).joined(separator: " ")
    }

    private static func hex(_ value: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(value >> 4)], digits[Int(value & 15)]])
    }
}

/// The lines a generated file's checkpoints share, which each checkpoint names by index.
package final class LinePool: Sendable {
    let lines: [Checkpoint.Line]

    /// Reads the file's pools. A cell is `[text, width, style]`, and a line is its wrap flag, 0 or 1,
    /// followed by its cells' indexes.
    package init(decoding data: Data) throws {
        struct Pools: Decodable {
            var cells: [Checkpoint.Cell]
            var lines: [[Int]]
        }
        let pools = try JSONDecoder().decode(Pools.self, from: data)
        lines = try pools.lines.map { line in
            guard let wrapped = line.first, line.dropFirst().allSatisfy(pools.cells.indices.contains) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid pooled line \(line)"))
            }
            return Checkpoint.Line(wrapped: wrapped == 1, cells: line.dropFirst().map { pools.cells[$0] })
        }
    }

    /// A decoder that reads each checkpoint line as an index into this pool.
    package var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.linePool] = self
        return decoder
    }
}

extension CodingUserInfoKey {
    static let linePool = CodingUserInfoKey(rawValue: "linePool")!
}
