// Owns the parser, screen and modes for one shell. Each chunk of output advances that
// state and returns any reply bytes the caller needs to send back to the shell.

/// The grid dimensions and colors used by a terminal pane.
public struct Terminal: Sendable {
    /// The pane’s visible dimensions in character cells, supplied to the socket factory.
    public struct Size: Equatable, Sendable {
        /// The number of visible character columns, with a minimum of two.
        public let columns: Int
        /// The number of visible character rows.
        public let rows: Int

        /// Creates a grid from positive dimensions, rounding a single column up to two for wide characters.
        package init(columns: Int, rows: Int) {
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

    /// The current dimensions of the visible grid in character cells.
    package var size: Size { screen.size }
    /// The colors reported to the shell when it queries the current theme.
    ///
    /// Set this when the host changes theme. Stored cells retain their original color indices.
    package var palette: Palette {
        didSet { if oldValue != palette { generation &+= 1 } }
    }
    package private(set) var modes = Modes()
    private var scanner = TextScanner()
    private var parser = EscapeParser()
    private var stringHandler = TerminalStringHandler()
    private var screen: Screen
    private var style = Style()
    private var savedStyle = Style()
    private var generation: UInt64 = 0
    private var hasCombiningBase = false

    /// Creates a terminal with a blank normal screen and the given colors for shell queries.
    package init(size: Size, palette: Palette = .default) {
        self.palette = palette
        screen = Screen(size: size)
    }

    /// Applies a chunk of shell output and returns any replies to send back to the shell.
    ///
    /// UTF-8 characters and escape sequences can span calls. An empty result means
    /// this chunk produced no reply. Forward nonempty results in arrival order.
    package mutating func receive(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        if let replies = bytes.withContiguousStorageIfAvailable({ receive($0.span) }) { return replies }
        var replies: [UInt8] = []
        for byte in bytes { consume(byte, replies: &replies) }
        return replies
    }

    /// Apply a borrowed network or replay buffer synchronously without copying it.
    package mutating func receive(_ bytes: Span<UInt8>) -> [UInt8] {
        var replies: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0x20, byte < 0x7f, parser.isGround, scanner.isComplete {
                let start = index
                index = TextScanner.endOfASCII(in: bytes, from: start)
                screen.writeASCII(bytes.extracting(start..<index), style: style)
                hasCombiningBase = true
                generation &+= 1
            } else {
                consume(byte, replies: &replies)
                index += 1
            }
        }
        return replies
    }

    /// Resizes the grid, reflowing normal-screen history at soft wraps and clipping the alternate screen.
    ///
    /// Send the same effective size to the PTY so the shell can redraw at the new dimensions.
    package mutating func resize(to size: Size) {
        guard size != screen.size else { return }
        screen.resize(to: size)
        generation &+= 1
    }

    /// Returns the text in a zero-based visible row, preserving printed spaces and omitting unused trailing cells.
    ///
    /// The top row is zero. The index must be less than `size.rows` and nonnegative.
    package func text(inRow row: Int) -> String {
        precondition((0..<size.rows).contains(row), "Row must be inside the visible grid")
        return screen.text(inRow: row)
    }

    /// A single, read-only generation for drawing, selection and accessibility.
    package func snapshot() -> Snapshot {
        screen.snapshot(generation: generation, modes: modes, palette: palette)
    }

    private mutating func consume(_ byte: UInt8, replies: inout [UInt8]) {
        guard let scalar = scanner.decode(byte), scalar.value != 0xfeff else { return }
        if parser.isGround, scalar.value >= 0xa0 || (0x20..<0x7f).contains(scalar.value) {
            let width = ColumnWidth.of(scalar)
            screen.write(scalar, width: width, style: style, joinsPrevious: hasCombiningBase)
            hasCombiningBase = width > 0 || hasCombiningBase
            generation &+= 1
            return
        }
        if scalar.value != 0x7f { hasCombiningBase = false }
        if let action = parser.consume(scalar), let function = TerminalControlFunction(action) { apply(function, replies: &replies) }
        if let pending = parser.takePendingAction(), let function = TerminalControlFunction(pending) {
            apply(function, replies: &replies)
        }
    }

    /// Applies one named VT function. Screen operations advance the frame generation together below.
    private mutating func apply(_ function: TerminalControlFunction, replies: inout [UInt8]) {
        switch function {
        case .execute(.backspace): screen.backspace()
        case .execute(.horizontalTab): screen.horizontalTab()
        case .execute(.lineFeed), .execute(.verticalTab), .execute(.formFeed): screen.lineFeed(style: style)
        case .execute(.carriageReturn): screen.carriageReturn()
        case .escape(.applicationKeypad):
            modes.applicationKeypad = true
            return
        case .escape(.numericKeypad):
            modes.applicationKeypad = false
            return
        case .control(.insertCharacters): screen.insertBlanks(parser.parameters[0, default: 1], style: style)
        case .control(.cursorUp): screen.cursorUp(parser.parameters[0, default: 1])
        case .control(.cursorDown): screen.cursorDown(parser.parameters[0, default: 1])
        case .control(.cursorForward): screen.cursorForward(parser.parameters[0, default: 1])
        case .control(.cursorBackward): screen.cursorBackward(parser.parameters[0, default: 1])
        case .control(.cursorPosition):
            screen.move(toRow: parser.parameters[0, default: 1] - 1, column: parser.parameters[1, default: 1] - 1)
        case .control(.eraseInDisplay):
            if let range = EraseRange(rawValue: parser.parameters[0]) { screen.eraseDisplay(range, style: style) }
        case .control(.eraseInLine):
            if let range = EraseRange(rawValue: parser.parameters[0]) { screen.eraseLine(range, style: style) }
        case .control(.deleteCharacters): screen.deleteCharacters(parser.parameters[0, default: 1], style: style)
        case .control(.primaryDeviceAttributes):
            if parser.parameters[0] == 0 { replies.append(contentsOf: "\u{1b}[?1;2c".utf8) }
            return
        case .control(.secondaryDeviceAttributes):
            if parser.parameters[0] == 0 { replies.append(contentsOf: "\u{1b}[>0;276;0c".utf8) }
            return
        case .control(.setPrivateMode):
            setPrivateModes(parser.parameters, enabled: true)
            return
        case .control(.resetPrivateMode):
            setPrivateModes(parser.parameters, enabled: false)
            return
        case .control(.graphicRendition):
            style.applySGR(parser.parameters)
            return
        case .control(.deviceStatusReport):
            if parser.parameters[0] == 6 { replies.append(contentsOf: "\u{1b}[\(screen.row + 1);\(screen.column + 1)R".utf8) }
            return
        case .control(.requestPrivateMode):
            if PrivateMode(rawValue: parser.parameters[0]) == .cursorBlink {
                replies.append(contentsOf: (modes.cursorBlink ? "\u{1b}[?12;1$y" : "\u{1b}[?12;2$y").utf8)
            }
            return
        case .control(.cursorStyle): setCursorStyle(parser.parameters[0])
        case .control(.scrollMargins):
            let top = parser.parameters[0, default: 1]
            let bottom = min(parser.parameters[1, default: size.rows], size.rows)
            guard top < bottom else { return }
            screen.setScrollRegion(top: top - 1, bottom: bottom - 1)
            screen.move(toRow: 0, column: 0)
        case .command(.indexedColor):
            stringHandler.start(.indexedColor)
            return
        case .command(.foregroundColor):
            stringHandler.start(.foregroundColor)
            return
        case .command(.backgroundColor):
            stringHandler.start(.backgroundColor)
            return
        case .ignoredString:
            parser.discardStringPayload()
            stringHandler.start(nil)
            return
        case .stringPut(let scalar):
            stringHandler.put(scalar)
            return
        case .stringEnd(let success):
            palette.appendReplies(to: &replies, for: stringHandler.finish(success: success))
            return
        }
        generation &+= 1
    }

    private mutating func setPrivateModes(_ parameters: ControlParameters, enabled: Bool) {
        for index in 0..<parameters.count {
            if let mode = PrivateMode(rawValue: parameters[index]) { setPrivateMode(mode, enabled: enabled) }
        }
    }

    private mutating func setCursorStyle(_ parameter: Int) {
        switch parameter {
        case 0...2: modes.cursorShape = .block
        case 3, 4: modes.cursorShape = .underline
        case 5, 6: modes.cursorShape = .bar
        default: break
        }
        modes.cursorBlinkOverride = parameter == 0 ? nil : !parameter.isMultiple(of: 2)
    }

    private mutating func setPrivateMode(_ mode: PrivateMode, enabled: Bool) {
        switch mode {
        case .applicationCursorKeys: modes.applicationCursorKeys = enabled
        case .cursorBlink:
            modes.cursorBlink = enabled
            generation &+= 1
        case .cursorVisible:
            modes.cursorVisible = enabled
            generation &+= 1
        case .applicationKeypad: modes.applicationKeypad = enabled
        case .mousePress, .mouseDrag, .mouseMotion:
            let next: MouseTracking = enabled ? (mode == .mousePress ? .press : mode == .mouseDrag ? .drag : .all) : .off
            if modes.mouseTracking != next {
                modes.mouseTracking = next
                generation &+= 1
            }
        case .mouseSGR: modes.mouseSGR = enabled
        case .sendFocus: modes.sendFocus = enabled
        case .alternateScreen:
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
        case .bracketedPaste: modes.bracketedPaste = enabled
        case .synchronizedOutput:
            // The presenter owns the timeout. Parsing, input and replies continue during a batch.
            generation &+= 1
            modes.synchronizedOutputID = enabled ? generation : nil
        }
    }
}
