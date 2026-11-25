// Owns the parser, screen and modes for one shell. Each chunk of output advances that
// state and returns any reply bytes the caller needs to send back to the shell.

/// A terminal emulator that applies shell output to a screen and encodes user input for the shell.
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
        /// IRM shifts the rest of the row right before each printed character.
        package var insert = false
        /// DECAWM moves printing to the next row at the right margin. Off, it overwrites the last column.
        package var wraparound = true
        /// LNM makes LF, VT and FF also return to the first column.
        var newLine = false
    }

    /// The current dimensions of the visible grid in character cells.
    package var size: Size { screen.size }
    /// The host theme's colors, which show wherever the program hasn't set its own.
    ///
    /// Set this when the host changes theme. Stored cells retain their original color indices.
    package var palette: Palette {
        didSet { if oldValue != palette { generation &+= 1 } }
    }
    /// The host theme's cursor color, which shows unless the program set its own.
    package var cursorColor: RGB {
        didSet { if oldValue != cursorColor { generation &+= 1 } }
    }
    /// The colors the program set over the host theme. They last until the program restores them,
    /// so a theme change or a resume never changes them.
    package private(set) var programColors = ProgramColors()
    package private(set) var modes = Modes()
    private(set) var scanner = TextScanner()
    private(set) var parser = EscapeParser()
    /// The completed window title. An empty title asks the host to use its default.
    package private(set) var title = ""
    private(set) var stringHandler = TerminalStringHandler()
    private(set) var screen: Screen
    private(set) var style = Style()
    private(set) var characterSets = CharacterSets()
    private var generation: UInt64 = 0
    // A preceding printable cell can accept a combining mark until an intervening control breaks the run.
    private(set) var hasCombiningBase = false

    /// Creates a terminal with a blank normal screen and the host theme's colors.
    package init(size: Size, palette: Palette = .default, cursorColor: RGB = .white) {
        self.palette = palette
        self.cursorColor = cursorColor
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
            if TextScanner.isPrintableASCII(byte), parser.isGround, scanner.isComplete, printsInRuns {
                let start = index
                index = TextScanner.endOfASCII(in: bytes, from: start)
                screen.writeASCII(bytes.extracting(start..<index), style: style)
                hasCombiningBase = true
                generation &+= 1
            } else if byte == EscapeParser.escape, scanner.isComplete {
                // Test ESC before C0 so each escape sequence skips a second control lookup.
                hasCombiningBase = false
                var borrowedParameters: Range<Int>?
                let action = parser.consumeEscape(
                    in: bytes, index: &index, borrowingParametersFor: TerminalControlFunction.CSI.graphicRendition.rawValue,
                    borrowedParameters: &borrowedParameters
                )
                if let borrowedParameters {
                    style.applySGR(bytes.extracting(borrowedParameters))
                } else {
                    dispatch(action, replies: &replies)
                }
            } else if byte >= 0x80, parser.isGround, printsInRuns {
                writeNonASCII(in: bytes, index: &index, replies: &replies)
            } else if let control = TerminalControlFunction.C0(rawValue: byte), parser.isGround, scanner.isComplete {
                // A single-byte C0 in ground state leaves the framer in ground state.
                hasCombiningBase = false
                apply(.execute(control), replies: &replies)
                index += 1
            } else if TextScanner.isPrintableASCII(byte), scanner.isComplete, parser.discardsASCII || stringHandler.isCollecting {
                let start = index
                index = TextScanner.endOfASCII(in: bytes, from: start)
                if stringHandler.isCollecting { stringHandler.appendASCII(bytes.extracting(start..<index)) }
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
        screen.snapshot(generation: generation, modes: modes, palette: palette, programColors: programColors)
    }

    /// Text prints in runs only when each character lands in the next cell as itself. Insert mode,
    /// disabled autowrap and a character set other than ASCII print one character at a time.
    private var printsInRuns: Bool { modes.wraparound && !modes.insert && characterSets.active == .ascii }

    private mutating func writeNonASCII(in bytes: Span<UInt8>, index: inout Int, replies: inout [UInt8]) {
        guard let first = scanner.nextNonASCII(in: bytes, index: &index) else { return }
        var control: Unicode.Scalar?
        if first.value < 0xa0 {
            control = first
        } else {
            var decoder = scanner
            let written = screen.writeRun(startingWith: (first, ColumnWidth.of(first)), style: style,
                                          joinsPrevious: &hasCombiningBase) {
                guard let scalar = decoder.nextNonASCII(in: bytes, index: &index) else { return nil }
                if scalar.value < 0xa0 {
                    control = scalar
                    return nil
                }
                return (scalar, ColumnWidth.of(scalar))
            }
            scanner = decoder
            generation &+= written
        }
        if let control {
            hasCombiningBase = false
            let action = parser.consume(control)
            dispatch(action, replies: &replies)
        }
    }

    @inline(__always)
    private mutating func consume(_ byte: UInt8, replies: inout [UInt8]) {
        if byte < 0x80, !parser.isGround || !TextScanner.isPrintableASCII(byte) {
            // An ASCII control also terminates any incomplete UTF-8 character.
            if !scanner.isComplete { scanner = TextScanner() }
            if byte != TextScanner.delete.value { hasCombiningBase = false }
            let action = parser.consume(ascii: byte)
            dispatch(action, replies: &replies)
            return
        }
        guard let scalar = scanner.decode(byte), scalar != TextScanner.byteOrderMark else { return }
        if parser.isGround, TextScanner.isPrintable(scalar) {
            let scalar = characterSets.active.translate(scalar)
            let width = ColumnWidth.of(scalar)
            screen.write(scalar, width: width, style: style, wraparound: modes.wraparound, insert: modes.insert, joinsPrevious: hasCombiningBase)
            hasCombiningBase = width > 0 || hasCombiningBase
            generation &+= 1
            return
        }
        if scalar != TextScanner.delete { hasCombiningBase = false }
        let action = parser.consume(scalar)
        dispatch(action, replies: &replies)
    }

    @inline(__always)
    private mutating func dispatch(_ action: EscapeParser.Action?, replies: inout [UInt8]) {
        if let action, let function = TerminalControlFunction(action) {
            apply(function, replies: &replies)
        }
        if let pending = parser.takePendingAction(), let function = TerminalControlFunction(pending) {
            apply(function, replies: &replies)
        }
    }

    /// Applies one named VT function. Screen operations advance the frame generation together below.
    private mutating func apply(_ function: TerminalControlFunction, replies: inout [UInt8]) {
        switch function {
        case .execute(.backspace): screen.backspace()
        case .execute(.horizontalTab): screen.horizontalTab()
        case .execute(.lineFeed), .execute(.verticalTab), .execute(.formFeed):
            if modes.newLine { screen.carriageReturn() }
            screen.lineFeed(style: style)
        case .execute(.carriageReturn): screen.carriageReturn()
        case .execute(.shiftIn):
            characterSets.invoke(0)
            return
        case .execute(.shiftOut), .escape(.lockingShift1Right):
            characterSets.invoke(1)
            return
        case .escape(.lockingShift2), .escape(.lockingShift2Right):
            characterSets.invoke(2)
            return
        case .escape(.lockingShift3), .escape(.lockingShift3Right):
            characterSets.invoke(3)
            return
        case .escape(.selectDefaultCharacterSet), .escape(.selectUTF8):
            characterSets.invoke(0)
            characterSets.designate(.ascii, slot: 0)
            return
        case .designate(let set, let slot):
            characterSets.designate(set, slot: slot)
            return
        case .escape(.saveCursor):
            saveCursor()
            return
        case .escape(.restoreCursor): restoreCursor()
        case .escape(.applicationKeypad):
            modes.applicationKeypad = true
            return
        case .escape(.numericKeypad):
            modes.applicationKeypad = false
            return
        case .escape(.index): screen.index(style: style)
        case .escape(.nextLine):
            screen.carriageReturn()
            screen.index(style: style)
        case .escape(.tabSet):
            screen.setTabStop()
            return
        case .escape(.reverseIndex): screen.reverseIndex(style: style)
        case .escape(.fullReset): fullReset()
        case .control(.insertCharacters): screen.insertBlanks(parser.parameters[0, default: 1], style: style)
        case .control(.cursorUp): screen.cursorUp(parser.parameters[0, default: 1])
        case .control(.cursorDown): screen.cursorDown(parser.parameters[0, default: 1])
        case .control(.cursorForward), .control(.columnRelative): screen.cursorForward(parser.parameters[0, default: 1])
        case .control(.cursorBackward): screen.cursorBackward(parser.parameters[0, default: 1])
        case .control(.cursorNextLine): screen.cursorNextLine(parser.parameters[0, default: 1])
        case .control(.cursorPrecedingLine): screen.cursorPrecedingLine(parser.parameters[0, default: 1])
        case .control(.cursorColumn), .control(.columnAbsolute):
            screen.move(toRow: screen.row, column: parser.parameters[0, default: 1] - 1)
        case .control(.rowAbsolute):
            screen.move(toRow: parser.parameters[0, default: 1] - 1, column: screen.column)
        case .control(.rowRelative):
            // Unlike CUD, VPR passes the bottom margin.
            screen.move(toRow: screen.row + parser.parameters[0, default: 1], column: screen.column)
        case .control(.cursorPosition), .control(.horizontalVerticalPosition):
            screen.move(toRow: parser.parameters[0, default: 1] - 1, column: parser.parameters[1, default: 1] - 1)
        case .control(.forwardTab): screen.horizontalTab(parser.parameters[0, default: 1])
        case .control(.backwardTab): screen.backwardTab(parser.parameters[0, default: 1])
        case .control(.tabClear):
            // TBC 0 clears the stop at the cursor and TBC 3 clears every stop.
            switch parser.parameters[0] {
            case 0: screen.clearTabStop()
            case 3: screen.clearAllTabStops()
            default: break
            }
            return
        case .control(.eraseInDisplay), .control(.selectiveEraseInDisplay):
            if parser.parameters[0] == 3 {
                screen.eraseHistory()
            } else if let range = EraseRange(rawValue: parser.parameters[0]) {
                screen.eraseDisplay(range, style: style)
            }
        case .control(.eraseInLine), .control(.selectiveEraseInLine):
            if let range = EraseRange(rawValue: parser.parameters[0]) { screen.eraseLine(range, style: style) }
        case .control(.insertLines): screen.insertLines(parser.parameters[0, default: 1], style: style)
        case .control(.deleteLines): screen.deleteLines(parser.parameters[0, default: 1], style: style)
        case .control(.deleteCharacters): screen.deleteCharacters(parser.parameters[0, default: 1], style: style)
        case .control(.scrollUp): screen.scrollUp(parser.parameters[0, default: 1], style: style)
        case .control(.scrollDown): screen.scrollDown(parser.parameters[0, default: 1])
        case .control(.eraseCharacters): screen.eraseCharacters(parser.parameters[0, default: 1], style: style)
        case .control(.primaryDeviceAttributes):
            if parser.parameters[0] == 0 { replies.append(contentsOf: Reply.primaryDeviceAttributes.utf8) }
            return
        case .control(.secondaryDeviceAttributes):
            if parser.parameters[0] == 0 { replies.append(contentsOf: Reply.secondaryDeviceAttributes.utf8) }
            return
        case .control(.setMode):
            setModes(enabled: true)
            return
        case .control(.resetMode):
            setModes(enabled: false)
            return
        case .control(.setPrivateMode):
            setPrivateModes(enabled: true)
            return
        case .control(.resetPrivateMode):
            setPrivateModes(enabled: false)
            return
        case .control(.graphicRendition):
            style.applySGR(parser.parameters)
            return
        case .control(.deviceStatusReport):
            // DSR 5 asks whether the terminal is working, and DSR 6 asks for the cursor position.
            switch parser.parameters[0] {
            case 5: replies.append(contentsOf: Reply.operatingStatus.utf8)
            case 6: replies.append(contentsOf: Reply.cursorPosition(row: screen.row, column: screen.column).utf8)
            default: break
            }
            return
        case .control(.privateDeviceStatusReport):
            if parser.parameters[0] == 6 {
                replies.append(contentsOf: Reply.privateCursorPosition(row: screen.row, column: screen.column).utf8)
            }
            return
        case .control(.requestMode):
            let mode = parser.parameters[0]
            replies.append(contentsOf: Reply.modeReport(mode, modeState(mode), isPrivate: false).utf8)
            return
        case .control(.requestPrivateMode):
            let mode = parser.parameters[0]
            replies.append(contentsOf: Reply.modeReport(mode, privateModeState(mode), isPrivate: true).utf8)
            return
        case .control(.cursorStyle): setCursorStyle(parser.parameters[0])
        case .control(.softReset): softReset()
        case .control(.scrollMargins):
            let top = parser.parameters[0, default: 1]
            let bottom = min(parser.parameters[1, default: size.rows], size.rows)
            guard top < bottom else { return }
            screen.setScrollRegion(top: top - 1, bottom: bottom - 1)
            screen.move(toRow: 0, column: 0)
        case .control(.saveCursor):
            saveCursor()
            return
        case .control(.restoreCursor): restoreCursor()
        case .command(let command):
            stringHandler.start(command)
            return
        case .ignoredString:
            parser.discardStringPayload()
            stringHandler.start(nil)
            return
        case .stringPut(let scalar):
            stringHandler.put(scalar)
            return
        case .stringEnd(let success):
            guard let string = stringHandler.finish(success: success) else { return }
            switch string.command {
            case .setIconAndWindowTitle, .setWindowTitle: title = string.payload
            default:
                if programColors.apply(string.command, payload: string.payload, palette: palette,
                                       cursor: cursorColor, replies: &replies) {
                    generation &+= 1
                }
            }
            return
        }
        generation &+= 1
    }

    private mutating func saveCursor() { screen.saveCursor(style: style, characterSet: characterSets.active) }

    private mutating func restoreCursor() {
        let saved = screen.restoreCursor()
        style = saved.style
        characterSets.active = saved.characterSet
    }

    /// DECSTR resets modes, margins, the style, the character sets and the saved cursor. It keeps the
    /// screen, the cursor position, mouse reporting and the program's colors.
    private mutating func softReset() {
        let mouse = (tracking: modes.mouseTracking, sgr: modes.mouseSGR)
        resetModes()
        modes.mouseTracking = mouse.tracking
        modes.mouseSGR = mouse.sgr
        screen.resetScrollRegion()
        screen.resetSavedCursor()
    }

    /// RIS also resets mouse reporting and starts both screens over, without history. It keeps the title
    /// and the colors, including those the program set.
    private mutating func fullReset() {
        resetModes()
        screen.reset()
    }

    /// Both resets return the modes, the style and the character sets to their defaults. LNM and the blink
    /// that DECSET 12 chose survive, as they do in the reference, where they are host settings.
    private mutating func resetModes() {
        var reset = Modes()
        reset.cursorBlink = modes.cursorBlink
        reset.newLine = modes.newLine
        modes = reset
        style = Style()
        characterSets = CharacterSets()
    }

    private mutating func setModes(enabled: Bool) {
        for index in 0..<parser.parameters.count {
            switch Mode(rawValue: parser.parameters[index]) {
            case .insert: modes.insert = enabled
            case .newLine: modes.newLine = enabled
            case nil: break
            }
        }
    }

    private func modeState(_ mode: Int) -> ModeState {
        switch Mode(rawValue: mode) {
        case .insert: ModeState(modes.insert)
        case .newLine: ModeState(modes.newLine)
        // The keyboard never locks (KAM, 2) and local echo stays off (SRM, 12).
        case nil: mode == 2 ? .permanentlyReset : mode == 12 ? .permanentlySet : .unrecognized
        }
    }

    private func privateModeState(_ mode: Int) -> ModeState {
        guard let mode = PrivateMode(rawValue: mode) else {
            return switch mode {
            // Origin mode, X10 mouse reports, reverse wraparound and pixel mouse coordinates stay off.
            case 6, 9, 45, 1016: .reset
            // Keys always autorepeat (DECARM, 8). Backspace sends DEL, and the UTF-8 and urxvt mouse encodings are unsupported.
            case 8: .permanentlySet
            case 67, 1005, 1015: .permanentlyReset
            default: .unrecognized
            }
        }
        return switch mode {
        case .applicationCursorKeys: ModeState(modes.applicationCursorKeys)
        case .ansi: .unrecognized
        case .wraparound: ModeState(modes.wraparound)
        case .cursorBlink: ModeState(modes.cursorBlink)
        case .cursorVisible: ModeState(modes.cursorVisible)
        case .applicationKeypad: ModeState(modes.applicationKeypad)
        case .mousePress: ModeState(modes.mouseTracking == .press)
        case .mouseDrag: ModeState(modes.mouseTracking == .drag)
        case .mouseMotion: ModeState(modes.mouseTracking == .all)
        case .sendFocus: ModeState(modes.sendFocus)
        case .mouseSGR: ModeState(modes.mouseSGR)
        // The reference reports 1048 as set, whatever was saved.
        case .saveCursor: .set
        case .alternateScreenOnly, .alternateScreenClearing, .alternateScreen: ModeState(screen.isAlternate)
        case .bracketedPaste: ModeState(modes.bracketedPaste)
        case .synchronizedOutput: ModeState(modes.synchronizedOutput)
        }
    }

    @inline(__always)
    private mutating func setPrivateModes(enabled: Bool) {
        for index in 0..<parser.parameters.count {
            if let mode = PrivateMode(rawValue: parser.parameters[index]) { setPrivateMode(mode, enabled: enabled) }
        }
    }

    private mutating func setCursorStyle(_ parameter: Int) {
        if let style = CursorStyleParameter(rawValue: parameter) { modes.cursorShape = style.shape }
        // Even an unknown style uses an odd value for blinking and an even value for steady.
        modes.cursorBlinkOverride = parameter == CursorStyleParameter.defaultStyle.rawValue ? nil : !parameter.isMultiple(of: 2)
    }

    private mutating func setMouseTracking(_ tracking: MouseTracking) {
        guard modes.mouseTracking != tracking else { return }
        modes.mouseTracking = tracking
        generation &+= 1
    }

    private mutating func setPrivateMode(_ mode: PrivateMode, enabled: Bool) {
        switch mode {
        case .applicationCursorKeys: modes.applicationCursorKeys = enabled
        case .ansi:
            guard enabled else { return }
            for slot in 0..<4 { characterSets.designate(.ascii, slot: slot) }
        case .wraparound: modes.wraparound = enabled
        case .cursorBlink:
            modes.cursorBlink = enabled
            generation &+= 1
        case .cursorVisible:
            modes.cursorVisible = enabled
            generation &+= 1
        case .applicationKeypad: modes.applicationKeypad = enabled
        case .mousePress, .mouseDrag, .mouseMotion:
            let tracking: MouseTracking = switch (enabled, mode) {
            case (true, .mousePress): .press
            case (true, .mouseDrag): .drag
            case (true, .mouseMotion): .all
            default: .off
            }
            setMouseTracking(tracking)
        case .mouseSGR: modes.mouseSGR = enabled
        case .sendFocus: modes.sendFocus = enabled
        case .saveCursor:
            if enabled { saveCursor() } else { restoreCursor() }
            generation &+= 1
        case .alternateScreen:
            // Leaving restores the normal screen's saved cursor even when the alternate screen wasn't active.
            if enabled { saveCursor() }
            screen.setAlternate(enabled, style: style)
            if !enabled { restoreCursor() }
            generation &+= 1
        case .alternateScreenOnly, .alternateScreenClearing:
            screen.setAlternate(enabled, style: style)
            generation &+= 1
        case .bracketedPaste: modes.bracketedPaste = enabled
        case .synchronizedOutput:
            // The presenter owns the timeout. Parsing, input and replies continue during a batch.
            generation &+= 1
            modes.synchronizedOutputID = enabled ? generation : nil
        }
    }
}
