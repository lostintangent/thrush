/// A synchronous terminal. Keep one value per shell and serialize output and input on its owner.
public struct Terminal: Sendable {
    public struct Size: Equatable, Sendable {
        public let columns: Int
        public let rows: Int

        public init(columns: Int, rows: Int) {
            precondition(columns > 0 && rows > 0, "Terminal dimensions must be positive")
            self.columns = columns
            self.rows = rows
        }
    }

    public enum Input: Sendable {
        case key(Key)

        public enum Key: Sendable {
            case up
        }
    }

    public let size: Size
    private var decoder = ScalarDecoder()
    private var parser = EscapeParser()
    private var screen: Screen
    private var applicationCursorKeys = false

    public init(size: Size) {
        self.size = size
        screen = Screen(size: size)
    }

    /// Apply PTY output in order, preserving incomplete UTF-8 and terminal sequences for the next call.
    /// The returned bytes are ready to send to the peer, in the order the queries arrived.
    public mutating func receive(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        var replies: [UInt8] = []
        for byte in bytes {
            if decoder.needsReplacement(before: byte) {
                decoder = ScalarDecoder()
                apply("\u{fffd}", replies: &replies)
            }
            if let scalar = decoder.decode(byte) {
                apply(scalar, replies: &replies)
            }
        }
        return replies
    }

    /// Encode local input under the current terminal modes. The shell supplies its own echo.
    public func encode(_ input: Input) -> [UInt8] {
        switch input {
        case .key(.up):
            applicationCursorKeys ? [0x1b, 0x4f, 0x41] : [0x1b, 0x5b, 0x41]
        }
    }

    /// Read a zero-based visible row. Printed spaces are preserved and unused trailing cells are omitted.
    public func text(inRow row: Int) -> String {
        screen.text(inRow: row)
    }

    private mutating func apply(_ scalar: Unicode.Scalar, replies: inout [UInt8]) {
        switch parser.consume(scalar) {
        case .print:
            screen.write(scalar)
        case .carriageReturn:
            screen.carriageReturn()
        case .lineFeed:
            screen.lineFeed()
        case .backspace:
            screen.backspace()
        case .applicationCursorKeys(let enabled):
            applicationCursorKeys = enabled
        case .cursorReport:
            replies.append(contentsOf: "\u{1b}[\(screen.row + 1);\(screen.column + 1)R".utf8)
        case nil:
            break
        }
    }
}

extension Terminal {
    /// Rows store only occupied single-column cells for the prompt repertoire.
    /// The column can sit one past the right margin until the next printable scalar wraps.
    private struct Screen: Sendable {
        let size: Size
        var row = 0
        var column = 0
        var lines: [[Unicode.Scalar]]

        init(size: Size) {
            self.size = size
            lines = Array(repeating: [], count: size.rows)
        }

        func text(inRow index: Int) -> String {
            String(String.UnicodeScalarView(lines[index]))
        }

        mutating func write(_ scalar: Unicode.Scalar) {
            if column == size.columns {
                column = 0
                lineFeed()
            }
            let count = lines[row].count
            if column < count {
                lines[row][column] = scalar
            } else {
                if column > count {
                    lines[row].append(contentsOf: repeatElement(" ", count: column - count))
                }
                lines[row].append(scalar)
            }
            column += 1
        }

        mutating func carriageReturn() {
            column = 0
        }

        mutating func lineFeed() {
            column = min(column, size.columns - 1)
            if row + 1 < size.rows {
                row += 1
            } else {
                lines.removeFirst()
                lines.append([])
            }
        }

        mutating func backspace() {
            column = max(0, min(column, size.columns - 1) - 1)
        }
    }
}
