import ThrushCore

/// Everything a program can observe about a terminal at one point in a conformance case.
///
/// The reference emulator and ThrushCore both report this shape, so a case passes when the two are equal.
/// The tooling in `Fixtures/reference/conformance` reads the same fields from the reference.
struct Checkpoint: Codable, Equatable, Sendable {
    struct Cursor: Codable, Equatable, Sendable {
        var row: Int
        var column: Int
        var visible: Bool
        var shape: String
        var blink: Bool
    }

    struct Modes: Codable, Equatable, Sendable {
        var applicationCursorKeys: Bool
        var applicationKeypad: Bool
        var bracketedPaste: Bool
        var insert: Bool
        var origin: Bool
        var wraparound: Bool
        var reverseWraparound: Bool
        var cursorBlink: Bool
        var sendFocus: Bool
        var synchronizedOutput: Bool
        var mouseTracking: String
        var mouseEncoding: String
    }

    /// One grid cell. Styles are space-separated attributes such as `fg=1 bold`, or empty for the default.
    struct Cell: Codable, Hashable, Sendable {
        static let blank = Cell(text: "", width: 1, style: "")

        var text: String
        var width: Int
        var style: String

        init(text: String, width: Int, style: String) {
            self.text = text
            self.width = width
            self.style = style
        }

        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            self.init(text: try container.decode(String.self), width: try container.decode(Int.self),
                      style: try container.decode(String.self))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(text)
            try container.encode(width)
            try container.encode(style)
        }
    }

    /// A row without its trailing blank cells. `wrapped` means it continues the row above.
    struct Line: Codable, Hashable, Sendable {
        var wrapped: Bool
        var cells: [Cell]

        subscript(column: Int) -> Cell { column < cells.count ? cells[column] : .blank }

        init(wrapped: Bool, cells: [Cell]) {
            self.wrapped = wrapped
            self.cells = cells
        }

        /// Generated case files name each line by its index in a shared pool.
        init(from decoder: any Decoder) throws {
            if let pool = decoder.userInfo[.linePool] as? LinePool {
                self = pool.lines[try decoder.singleValueContainer().decode(Int.self)]
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wrapped = try container.decode(Bool.self, forKey: .wrapped)
            cells = try container.decode([Cell].self, forKey: .cells)
        }
    }

    struct Screen: Codable, Equatable, Sendable {
        /// Scrolled-off rows, oldest first. Absent when the checkpoint only records the visible grid.
        var history: [Line]?
        var visible: [Line]
    }

    var name: String
    var size: [Int]
    var cursor: Cursor
    var buffer: String
    var modes: Modes
    var title: String
    /// The bytes the terminal sent back since the previous checkpoint, one character per byte.
    var replies: String
    var active: Screen
    /// The normal screen while the alternate screen is active, as the user returns to it.
    var normal: Screen?
    /// What the reference threw while processing the writes before this checkpoint. Thrush never sets it.
    var error: String?
}

extension Checkpoint {
    init(_ terminal: Terminal, name: String, includesHistory: Bool, replies: [UInt8]) {
        let snapshot = terminal.snapshot()
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
        title = terminal.title
        self.replies = String(String.UnicodeScalarView(replies.map(Unicode.Scalar.init)))
        active = Screen(snapshot, includesHistory: includesHistory)
        if snapshot.isAlternate && includesHistory {
            // Leaving the alternate screen on a copy reveals the normal screen as the user returns to it.
            var normal = terminal
            _ = normal.receive(Array("\u{1b}[?1049l".utf8))
            self.normal = Screen(normal.snapshot(), includesHistory: true)
        }
    }
}

extension Checkpoint.Screen {
    init(_ snapshot: Terminal.Snapshot, includesHistory: Bool) {
        let columns = snapshot.size.columns
        visible = snapshot.rows.map { Checkpoint.Line($0, columns: columns) }
        history = includesHistory ? snapshot.history.map { Checkpoint.Line($0, columns: columns) } : nil
    }
}

extension Checkpoint.Line {
    init(_ row: Terminal.Row, columns: Int) {
        wrapped = row.isWrapped
        cells = (0..<columns).map { column in
            let cell = row[column]
            return Checkpoint.Cell(text: cell.text, width: cell.width, style: Checkpoint.style(cell.style))
        }
        while cells.last == .blank { cells.removeLast() }
    }
}

extension Checkpoint {
    static func style(_ style: Terminal.Style) -> String {
        func color(_ color: Terminal.Color, _ kind: String) -> String? {
            switch color {
            case .default: nil
            case .indexed(let index): "\(kind)=\(index)"
            case .rgb(let red, let green, let blue): "\(kind)=#" + [red, green, blue].map(hex).joined()
            }
        }
        let attributes = [
            (style.bold, "bold"), (style.dim, "dim"), (style.italic, "italic"), (style.underline, "underline"),
            (style.blink, "blink"), (style.inverse, "inverse"), (style.invisible, "invisible"),
            (style.strikethrough, "strikethrough"),
        ]
        let colors = [color(style.foreground, "fg"), color(style.background, "bg")].compactMap(\.self)
        return (colors + attributes.filter(\.0).map(\.1)).joined(separator: " ")
    }

    private static func hex(_ value: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(value >> 4)], digits[Int(value & 15)]])
    }
}
