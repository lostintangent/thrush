/// A synchronous terminal. Keep one value per shell and serialize output, resize and input on its owner.
public struct Terminal: Sendable {
    /// A grid size in character cells.
    public struct Size: Equatable, Sendable {
        public let columns: Int
        public let rows: Int

        /// Record the effective server dimensions. xterm reserves at least two columns for wide glyphs.
        public init(columns: Int, rows: Int) {
            precondition(columns > 0 && rows > 0, "Terminal dimensions must be positive")
            self.columns = max(2, columns)
            self.rows = rows
        }
    }

    package enum CursorShape: String, Sendable {
        case block, underline, bar
    }

    package struct Modes: Equatable, Sendable {
        package var applicationCursorKeys = false
        package var applicationKeypad = false
        package var bracketedPaste = false
        package var cursorVisible = true
        package var cursorBlink = false
        var cursorShape: CursorShape = .block
        var cursorBlinkOverride: Bool?
        package var mouseTracking: MouseTracking = .off
        package var mouseSGR = false
        package var sendFocus = false
        var synchronizedOutputID: UInt64?
        package var synchronizedOutput: Bool { synchronizedOutputID != nil }
        package let origin = false
        package let insert = false
        package let wraparound = true
    }

    /// The visible grid. History sits above it.
    public var size: Size { screen.size }
    /// Change this when the host changes theme. Stored cells retain their semantic colors.
    public var palette: Palette {
        didSet { if oldValue != palette { generation &+= 1 } }
    }
    package private(set) var modes = Modes()
    private var decoder = ScalarDecoder()
    private var parser = EscapeParser()
    private var screen: Screen
    private var style = Style()
    private var savedStyle = Style()
    private var generation: UInt64 = 0
    private var hasCombiningBase = false

    /// Start on a blank normal screen. The palette resolves colors and answers OSC color queries.
    public init(size: Size, palette: Palette = .default) {
        self.palette = palette
        screen = Screen(size: size)
    }

    /// Apply PTY output in order. UTF-8 and control sequences may span arbitrary calls.
    /// Replies are ready to send to the peer in the order the queries arrived.
    public mutating func receive(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        if let replies = bytes.withContiguousStorageIfAvailable({ receive($0) }) { return replies }
        var replies: [UInt8] = []
        for byte in bytes { consume(byte, replies: &replies) }
        return replies
    }

    /// Apply a borrowed network or replay buffer synchronously without copying it.
    public mutating func receive(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var replies: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x20, byte < 0x7f, parser.isGround, decoder.isComplete {
                let start = index
                repeat { index += 1 } while index < bytes.count && bytes[index] >= 0x20 && bytes[index] < 0x7f
                screen.writeASCII(UnsafeBufferPointer(rebasing: bytes[start..<index]), style: style)
                hasCombiningBase = true
                generation &+= 1
            } else {
                consume(byte, replies: &replies)
                index += 1
            }
        }
        return replies
    }

    /// Apply the PTY's new size. Normal history reflows at soft wraps, and the alternate screen clips.
    public mutating func resize(to size: Size) {
        guard size != screen.size else { return }
        screen.resize(to: size)
        generation &+= 1
    }

    /// Read a zero-based visible row. Printed spaces survive, while unused trailing cells are omitted.
    public func text(inRow row: Int) -> String {
        precondition((0..<size.rows).contains(row), "Row must be inside the visible grid")
        return screen.text(inRow: row)
    }

    /// A single, read-only generation for drawing, selection and accessibility.
    package func snapshot() -> Snapshot {
        screen.snapshot(generation: generation, modes: modes, palette: palette)
    }

    private mutating func consume(_ byte: UInt8, replies: inout [UInt8]) {
        if decoder.needsRestart(before: byte) { decoder = ScalarDecoder() }
        guard let scalar = decoder.decode(byte), scalar.value != 0xfeff else { return }
        let action = parser.consume(scalar)
        if case .printable = action {
            let width = ColumnWidth.of(scalar)
            screen.write(scalar, width: width, style: style, joinsPrevious: hasCombiningBase)
            hasCombiningBase = width > 0 || hasCombiningBase
            generation &+= 1
            return
        }
        if scalar.value != 0x7f { hasCombiningBase = false }
        switch action {
        case .carriageReturn: screen.carriageReturn()
        case .lineFeed: screen.lineFeed(style: style)
        case .backspace: screen.backspace()
        case .colorQueries(let queries):
            palette.appendReplies(to: &replies, for: queries)
            return
        case .keypad(let enabled):
            modes.applicationKeypad = enabled
            return
        case .csi(let final, let prefix, let intermediate, let parameters):
            handleCSI(final, prefix: prefix, intermediate: intermediate, parameters: parameters, replies: &replies)
            return
        case nil, .printable: return
        }
        generation &+= 1
    }

    private mutating func handleCSI(
        _ final: UInt8, prefix: UInt8?, intermediate: UInt8?, parameters: [Int], replies: inout [UInt8]
    ) {
        let first = parameters[0]
        switch (prefix, intermediate, final) {
        case (nil, 0x20, 0x71): // DECSCUSR overrides the cursor until a zero or omitted parameter.
            switch first {
            case 0...2: modes.cursorShape = .block
            case 3, 4: modes.cursorShape = .underline
            case 5, 6: modes.cursorShape = .bar
            default: break
            }
            modes.cursorBlinkOverride = first == 0 ? nil : !first.isMultiple(of: 2)
            generation &+= 1
            return
        case (nil, nil, 0x63) where first == 0:
            // Codex probes primary device attributes alongside its optional keyboard query.
            replies.append(contentsOf: "\u{1b}[?1;2c".utf8)
            return
        case (0x3e, nil, 0x63) where first == 0:
            // Secondary device attributes advertised by the server's configured xterm.
            replies.append(contentsOf: "\u{1b}[>0;276;0c".utf8)
            return
        case (0x3f, 0x24, 0x70) where first == 12:
            // Vim probes cursor blink before changing it. DECRQM reports set (1) or reset (2).
            replies.append(contentsOf: (modes.cursorBlink ? "\u{1b}[?12;1$y" : "\u{1b}[?12;2$y").utf8)
            return
        case (0x3f, nil, 0x68), (0x3f, nil, 0x6c):
            for mode in parameters { setPrivateMode(mode, enabled: final == 0x68) }
            return
        case (nil, nil, _): break
        default: return
        }

        switch final {
        case 0x41, 0x42: // CUU/CUD stop at the scroll margin when approached from inside it.
            let count = max(1, first)
            let row = screen.row
            let target: Int
            if final == 0x41 {
                target = max(row >= screen.scrollTop ? screen.scrollTop : 0, row - count)
            } else {
                target = min(row <= screen.scrollBottom ? screen.scrollBottom : size.rows - 1, row + count)
            }
            screen.move(toRow: target, column: screen.column)
        case 0x43: // CUF advances over unwritten cells when Vim draws an indented line.
            screen.move(toRow: screen.row, column: screen.column + max(1, first))
        case 0x44: // CUB measures from the visible right margin even when wrapping is pending.
            screen.move(toRow: screen.row, column: min(screen.column, size.columns - 1) - max(1, first))
        case 0x48: // CUP
            let column = parameters.count > 1 ? parameters[1] : 1
            screen.move(toRow: max(1, first) - 1, column: max(1, column) - 1)
        case 0x4a: screen.eraseDisplay(first, style: style)
        case 0x4b: screen.eraseLine(first, style: style)
        case 0x6d:
            style.applySGR(parameters)
            return
        case 0x6e where first == 6:
            replies.append(contentsOf: "\u{1b}[\(screen.row + 1);\(screen.column + 1)R".utf8)
            return
        case 0x72: // DECSTBM homes the cursor after a valid change of margins.
            let top = max(1, first)
            let specified = parameters.count > 1 ? parameters[1] : 0
            let bottom = specified == 0 ? size.rows : min(specified, size.rows)
            guard top < bottom else { return }
            screen.setScrollRegion(top: top - 1, bottom: bottom - 1)
            screen.move(toRow: 0, column: 0)
        default: return
        }
        generation &+= 1
    }

    private mutating func setPrivateMode(_ mode: Int, enabled: Bool) {
        switch mode {
        case 1: modes.applicationCursorKeys = enabled
        case 12:
            modes.cursorBlink = enabled
            generation &+= 1
        case 25:
            modes.cursorVisible = enabled
            generation &+= 1
        case 66: modes.applicationKeypad = enabled
        case 1000, 1002, 1003:
            let next: MouseTracking = enabled ? (mode == 1000 ? .press : mode == 1002 ? .drag : .all) : .off
            if modes.mouseTracking != next {
                modes.mouseTracking = next
                generation &+= 1
            }
        case 1006: modes.mouseSGR = enabled
        case 1004: modes.sendFocus = enabled
        case 1049:
            guard enabled != screen.isAlternate else { return }
            if enabled {
                screen.saveCursor()
                savedStyle = style
            }
            screen.setAlternate(enabled, style: style)
            if !enabled {
                screen.restoreCursor()
                style = savedStyle
            }
            generation &+= 1
        case 2004: modes.bracketedPaste = enabled
        case 2026:
            // The presenter owns the timeout. Parsing, input and replies continue during a batch.
            generation &+= 1
            modes.synchronizedOutputID = enabled ? generation : nil
        default: break
        }
    }
}
