// Owns the parser, screen and modes for one shell. Each chunk of output advances that
// state and returns any reply bytes the caller needs to send back to the shell.

/// A terminal emulator that applies shell output to a screen and encodes user input for the shell.
public struct Terminal: Sendable {
    /// The terminal’s visible dimensions in character cells, supplied to the socket factory.
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
        /// DECOM counts rows from the top margin and keeps the cursor within the scroll region.
        package var origin = false
        /// IRM shifts the rest of the row right before each printed character.
        package var insert = false
        /// DECAWM moves printing to the next row at the right margin. Off, it overwrites the last column.
        package var wraparound = true
        /// Reverse wraparound lets BS reach the last column from a pending wrap and back over a soft wrap.
        package var reverseWraparound = false
        /// LNM makes LF, VT and FF also return to the first column.
        var newLine = false
        /// Mode 2031 asks the app to report each change between a dark and a light theme.
        package var reportAppearance = false
    }

    /// Whether the app's theme is dark or light. The raw value is the parameter of its report.
    package enum Appearance: Int, Sendable {
        case dark = 1
        case light = 2
    }

    /// The current dimensions of the visible grid in character cells.
    package var size: Size { screen.size }
    /// The colors of the app's theme, which show wherever the program hasn't set its own.
    ///
    /// Set this when the app changes theme. Stored cells retain their original color indices.
    package var palette: Palette {
        didSet { if oldValue != palette { generation &+= 1 } }
    }
    /// The cursor color of the app's theme, which shows unless the program set its own.
    package var cursorColor: RGB {
        didSet { if oldValue != cursorColor { generation &+= 1 } }
    }
    /// Whether the app shows the terminal with keyboard focus. A program that sets mode 1004 hears it
    /// right away, then hears each change the app sends as ``Input/focus(_:)``. Resets keep it.
    package var isFocused = false
    /// Whether the app's theme is dark or light. A program can ask with DECDSR 996, and one that sets
    /// mode 2031 hears each change the app sends as ``Input/appearance(_:)``. It's unknown until the app
    /// supplies it, so a headless terminal leaves the question unanswered. Resets keep it.
    package var appearance: Appearance?
    /// The colors the program set over the app's theme. They last until the program restores them,
    /// so a theme change or a resume never changes them.
    package private(set) var programColors = ProgramColors()
    package private(set) var modes = Modes()
    private(set) var parser = Parser()
    /// The completed window title. An empty title asks the app to use its default.
    package private(set) var title = ""
    /// Text the program copied with OSC 52 that the app hasn't put on the pasteboard yet. Each copy
    /// replaces the one before, so the app takes it after applying output.
    package var copiedText: String?
    private(set) var screen: Screen
    private(set) var style = Style()
    private(set) var characterSets = CharacterSets()
    private var generation: UInt64 = 0
    // Printed text runs up to the cursor until a control function is performed. Until then a combining
    // mark joins the last character and REP repeats it. A sequence that is incomplete or ignored keeps the run.
    private(set) var followsText = false

    /// Creates a terminal with a blank normal screen and the colors of the app's theme.
    package init(size: Size, palette: Palette = .default, cursorColor: RGB = .white) {
        self.init(screen: Screen(size: size), palette: palette, cursorColor: cursorColor)
    }

    private init(screen: Screen, palette: Palette, cursorColor: RGB) {
        self.screen = screen
        self.palette = palette
        self.cursorColor = cursorColor
    }

    /// Starts a replacement shell at the top of a blank grid, with the previous main screen in history.
    package mutating func startNewShell(at size: Size) {
        restart(at: size, includingCurrentShell: true)
    }

    /// A replay supplies the current shell's history and screen. Earlier shells belong to the app.
    package mutating func prepareForReplay(at size: Size) {
        restart(at: size, includingCurrentShell: false)
    }

    private mutating func restart(at size: Size, includingCurrentShell: Bool) {
        let nextScreen = screen.startingShell(at: size, includingCurrentShell: includingCurrentShell)
        var next = Self(screen: nextScreen, palette: palette, cursorColor: cursorColor)
        next.isFocused = isFocused
        next.appearance = appearance
        next.generation = generation &+ 1
        self = next
    }

    /// Applies a chunk of shell output and returns any replies to send back to the shell.
    ///
    /// UTF-8 characters and escape sequences can span calls. An empty result means
    /// this chunk produced no reply. Forward nonempty results in arrival order.
    package mutating func receive(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        if let replies = bytes.withContiguousStorageIfAvailable({ receive($0.span) }) { return replies }
        let copy = Array(bytes)
        return receive(copy.span)
    }

    /// Apply a borrowed network or replay buffer synchronously without copying it.
    ///
    /// The parser reads the chunk as text to print and functions to perform.
    package mutating func receive(_ bytes: Span<UInt8>) -> [UInt8] {
        var replies: [UInt8] = []
        var index = 0
        while let token = parser.next(in: bytes, from: &index) {
            switch token {
            case .text(let text): print(text, from: bytes)
            case .function(.csi(.graphicRendition)):
                // SGR never touches the screen. It only changes the pen the next text prints with,
                // and reads a whole header straight from the chunk.
                style.applySGR(&parser.parameters, in: bytes)
                followsText = false
            case .function(let function): perform(function, replies: &replies)
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

    /// Prints a run of ASCII from the chunk or the glyphs the parser decoded.
    @inline(__always)
    private mutating func print(_ text: Parser.Text, from bytes: Span<UInt8>) {
        guard printsInRuns else { return printEach(text, from: bytes) }
        switch text {
        case .ascii(let run):
            screen.writeASCII(bytes.extracting(run), style: style)
            followsText = true
            generation &+= 1
        case .glyphs(let count):
            generation &+= screen.writeRun(parser.glyphs.span.extracting(..<count), style: style, joinsPrevious: &followsText)
        }
    }

    /// Prints one character at a time through the active character set, in insert mode or with autowrap off.
    private mutating func printEach(_ text: Parser.Text, from bytes: Span<UInt8>) {
        func print(_ scalar: Unicode.Scalar) {
            let scalar = characterSets.active.translate(scalar)
            let width = ColumnWidth.of(scalar)
            screen.write(scalar, width: width, style: style, wraparound: modes.wraparound, insert: modes.insert,
                         joinsPrevious: followsText)
            followsText = width > 0 || followsText
            generation &+= 1
        }
        switch text {
        case .ascii(let run):
            for index in run { print(Unicode.Scalar(bytes[index])) }
        case .glyphs(let count):
            for index in 0..<count {
                if let scalar = Unicode.Scalar(StoredCell(glyph: parser.glyphs[index]).scalar) { print(scalar) }
            }
        }
    }

    /// Performs one named function, which ends the text run.
    @inline(__always)
    private mutating func perform(_ function: ControlFunction, replies: inout [UInt8]) {
        switch function {
        case .c0(let function): perform(function)
        case .escape(let function): perform(function)
        case .designate(let set, let slot): characterSets.designate(set, slot: slot)
        case .csi(let function): perform(function, replies: &replies)
        case .osc(let function): perform(function, replies: &replies)
        case .dcs(let function): perform(function, replies: &replies)
        case .unsupported: break
        }
        followsText = false
    }

    // Each family's functions that change the screen advance the frame generation together at the end.

    private mutating func perform(_ function: ControlFunction.C0) {
        switch function {
        case .backspace: screen.backspace(reverseWraparound: modes.reverseWraparound)
        case .horizontalTab: screen.horizontalTab()
        case .lineFeed, .verticalTab, .formFeed:
            if modes.newLine { screen.carriageReturn() }
            screen.lineFeed(style: style)
        case .carriageReturn: screen.carriageReturn()
        case .shiftIn:
            characterSets.invoke(0)
            return
        case .shiftOut:
            characterSets.invoke(1)
            return
        }
        generation &+= 1
    }

    private mutating func perform(_ function: ControlFunction.Escape) {
        switch function {
        case .lockingShift1Right:
            characterSets.invoke(1)
            return
        case .lockingShift2, .lockingShift2Right:
            characterSets.invoke(2)
            return
        case .lockingShift3, .lockingShift3Right:
            characterSets.invoke(3)
            return
        case .selectDefaultCharacterSet, .selectUTF8:
            characterSets.invoke(0)
            characterSets.designate(.ascii, slot: 0)
            return
        case .saveCursor:
            saveCursor()
            return
        case .restoreCursor: restoreCursor()
        case .applicationKeypad:
            modes.applicationKeypad = true
            return
        case .numericKeypad:
            modes.applicationKeypad = false
            return
        case .index: screen.index(style: style)
        case .nextLine:
            screen.carriageReturn()
            screen.index(style: style)
        case .tabSet:
            screen.setTabStop()
            return
        case .reverseIndex: screen.reverseIndex(style: style)
        case .screenAlignmentPattern:
            // As DEC specifies, DECALN fills the whole screen and resets the margins before homing.
            screen.fillWithAlignmentPattern(style: style.alignmentStyle)
            screen.resetScrollRegion()
            position(row: 0, column: 0)
        case .fullReset: fullReset()
        }
        generation &+= 1
    }

    /// Reads the parser's parameters.
    private mutating func perform(_ function: ControlFunction.CSI, replies: inout [UInt8]) {
        switch function {
        case .insertCharacters: screen.insertBlanks(parser.parameters[0, default: 1], style: style)
        case .cursorUp: screen.cursorUp(parser.parameters[0, default: 1])
        case .cursorDown: screen.cursorDown(parser.parameters[0, default: 1])
        case .cursorForward, .columnRelative: screen.cursorForward(parser.parameters[0, default: 1])
        case .cursorBackward: screen.cursorBackward(parser.parameters[0, default: 1])
        case .cursorNextLine: screen.cursorNextLine(parser.parameters[0, default: 1])
        case .cursorPrecedingLine: screen.cursorPrecedingLine(parser.parameters[0, default: 1])
        case .cursorColumn, .columnAbsolute:
            screen.move(toRow: screen.row, column: parser.parameters[0, default: 1] - 1)
        case .repeatPrecedingCharacter:
            // REP repeats a character only when it was printed right before the sequence.
            guard followsText else { return }
            screen.repeatPrecedingCharacter(parser.parameters[0, default: 1], style: style,
                                            wraparound: modes.wraparound, insert: modes.insert)
        case .rowAbsolute:
            position(row: parser.parameters[0, default: 1] - 1, column: screen.column)
        case .rowRelative:
            // Unlike CUD, VPR passes the bottom margin, unless origin mode keeps the cursor within it.
            position(row: screen.row - originTop + parser.parameters[0, default: 1], column: screen.column)
        case .cursorPosition, .horizontalVerticalPosition:
            position(row: parser.parameters[0, default: 1] - 1, column: parser.parameters[1, default: 1] - 1)
        case .forwardTab: screen.horizontalTab(parser.parameters[0, default: 1])
        case .backwardTab: screen.backwardTab(parser.parameters[0, default: 1])
        case .tabClear:
            // TBC 0 clears the stop at the cursor and TBC 3 clears every stop.
            switch parser.parameters[0] {
            case 0: screen.clearTabStop()
            case 3: screen.clearAllTabStops()
            default: break
            }
            return
        case .eraseInDisplay, .selectiveEraseInDisplay:
            if parser.parameters[0] == 3 {
                screen.eraseHistory()
            } else if let range = EraseRange(rawValue: parser.parameters[0]) {
                screen.eraseDisplay(range, style: style)
            }
        case .eraseInLine, .selectiveEraseInLine:
            if let range = EraseRange(rawValue: parser.parameters[0]) { screen.eraseLine(range, style: style) }
        case .insertLines: screen.insertLines(parser.parameters[0, default: 1], style: style)
        case .deleteLines: screen.deleteLines(parser.parameters[0, default: 1], style: style)
        case .deleteCharacters: screen.deleteCharacters(parser.parameters[0, default: 1], style: style)
        case .scrollUp: screen.scrollUp(parser.parameters[0, default: 1], style: style)
        case .scrollDown: screen.scrollDown(parser.parameters[0, default: 1])
        case .eraseCharacters: screen.eraseCharacters(parser.parameters[0, default: 1], style: style)
        case .insertColumns:
            screen.editColumns(.insert, at: screen.column, count: parser.parameters[0, default: 1], style: style)
        case .deleteColumns:
            screen.editColumns(.delete, at: screen.column, count: parser.parameters[0, default: 1], style: style)
        case .scrollLeft: screen.editColumns(.delete, at: 0, count: parser.parameters[0, default: 1], style: style)
        case .scrollRight: screen.editColumns(.insert, at: 0, count: parser.parameters[0, default: 1], style: style)
        case .primaryDeviceAttributes:
            if parser.parameters[0] == 0 { replies.append(contentsOf: Reply.primaryDeviceAttributes.utf8) }
            return
        case .secondaryDeviceAttributes:
            if parser.parameters[0] == 0 { replies.append(contentsOf: Reply.secondaryDeviceAttributes.utf8) }
            return
        case .setMode:
            setModes(enabled: true)
            return
        case .resetMode:
            setModes(enabled: false)
            return
        case .setPrivateMode:
            setPrivateModes(enabled: true, replies: &replies)
            return
        case .resetPrivateMode:
            setPrivateModes(enabled: false, replies: &replies)
            return
        case .graphicRendition:
            // Receive gives SGR to the pen.
            return
        case .deviceStatusReport:
            // DSR 5 asks whether the terminal is working, and DSR 6 asks for the cursor position.
            switch parser.parameters[0] {
            case 5: replies.append(contentsOf: Reply.operatingStatus.utf8)
            case 6: replies.append(contentsOf: Reply.cursorPosition(row: screen.row - originTop, column: screen.column).utf8)
            default: break
            }
            return
        case .privateDeviceStatusReport:
            // DECDSR 6 asks for the cursor position, and 996 asks whether the theme is dark or light.
            switch parser.parameters[0] {
            case 6: replies.append(contentsOf: Reply.privateCursorPosition(row: screen.row - originTop, column: screen.column).utf8)
            case 996: if let appearance { replies.append(contentsOf: Reply.appearance(appearance).utf8) }
            default: break
            }
            return
        case .requestMode:
            let mode = parser.parameters[0]
            replies.append(contentsOf: Reply.modeReport(mode, modeState(mode), isPrivate: false).utf8)
            return
        case .requestPrivateMode:
            let mode = parser.parameters[0]
            replies.append(contentsOf: Reply.modeReport(mode, privateModeState(mode), isPrivate: true).utf8)
            return
        case .cursorStyle: setCursorStyle(parser.parameters[0])
        case .softReset: softReset()
        case .scrollMargins:
            let top = parser.parameters[0, default: 1]
            let bottom = min(parser.parameters[1, default: size.rows], size.rows)
            guard top < bottom else { return }
            screen.setScrollRegion(top: top - 1, bottom: bottom - 1)
            position(row: 0, column: 0)
        case .saveCursor:
            saveCursor()
            return
        case .restoreCursor: restoreCursor()
        }
        generation &+= 1
    }

    /// Reads the parser's payload. Only program colors change what the screen shows.
    private mutating func perform(_ function: ControlFunction.OSC, replies: inout [UInt8]) {
        switch function {
        case .setIconAndWindowTitle, .setWindowTitle: title = parser.payload.text
        case .hyperlink:
            switch Link.command(parser.payload.text) {
            case .open(let link): style.link = screen.number(for: link, pen: style)
            case .close: style.link = 0
            case nil: break
            }
        case .clipboard:
            if let text = Self.clipboardText(parser.payload.text) { copiedText = text }
        default:
            if programColors.apply(function, payload: parser.payload.text, palette: palette,
                                   cursor: cursorColor, replies: &replies) {
                generation &+= 1
            }
        }
    }

    /// Reads the parser's payload, and only replies.
    private mutating func perform(_ function: ControlFunction.DCS, replies: inout [UInt8]) {
        switch function {
        case .requestStatusString:
            let cursorStyle = CursorStyleParameter(modes.cursorShape,
                                                   blinking: modes.cursorBlinkOverride ?? modes.cursorBlink)
            replies += Reply.statusString(parser.payload.text, style: style, cursorStyle: cursorStyle,
                                          scrollTop: screen.scrollTop, scrollBottom: screen.scrollBottom).utf8
        case .requestCapabilities:
            replies += Reply.capabilities(parser.payload.bytes)
        }
    }

    /// The rows CUP and VPA count from. Origin mode counts from the top margin.
    private var originTop: Int { modes.origin ? screen.scrollTop : 0 }

    /// Places the cursor for the controls that address a row, which origin mode keeps within the region.
    private mutating func position(row: Int, column: Int) {
        screen.move(toRow: modes.origin ? min(screen.scrollTop + row, screen.scrollBottom) : row, column: column)
    }

    /// DECSC saves the position, the style and the character set. It leaves out origin mode, as the
    /// reference does, since no workflow needs it.
    private mutating func saveCursor() { screen.saveCursor(style: style, characterSet: characterSets.active) }

    /// The link stays open across a restore, as it does across SGR 0, since it isn't a rendition.
    private mutating func restoreCursor() {
        let saved = screen.restoreCursor()
        let link = style.link
        style = saved.style
        style.link = link
        characterSets.active = saved.characterSet
        if modes.origin { screen.moveIntoScrollRegion() }
    }

    /// DECSTR resets modes, margins, the style, the character sets and the saved cursor. It keeps the
    /// screen, the cursor position, mouse reporting, appearance reports and the program's colors.
    private mutating func softReset() {
        let kept = (tracking: modes.mouseTracking, sgr: modes.mouseSGR, appearance: modes.reportAppearance)
        resetModes()
        modes.mouseTracking = kept.tracking
        modes.mouseSGR = kept.sgr
        modes.reportAppearance = kept.appearance
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
    /// that DECSET 12 chose survive, as they do in the reference, where the app sets them.
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
            // X10 mouse reports and pixel mouse coordinates stay off.
            case 9, 1016: .reset
            // Keys always autorepeat (DECARM, 8). Backspace sends DEL, and the UTF-8 and urxvt mouse encodings are unsupported.
            case 8: .permanentlySet
            case 67, 1005, 1015: .permanentlyReset
            default: .unrecognized
            }
        }
        return switch mode {
        case .applicationCursorKeys: ModeState(modes.applicationCursorKeys)
        case .ansi: .unrecognized
        case .origin: ModeState(modes.origin)
        case .wraparound: ModeState(modes.wraparound)
        case .reverseWraparound: ModeState(modes.reverseWraparound)
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
        case .reportAppearance: ModeState(modes.reportAppearance)
        }
    }

    private mutating func setPrivateModes(enabled: Bool, replies: inout [UInt8]) {
        for index in 0..<parser.parameters.count {
            guard let mode = PrivateMode(rawValue: parser.parameters[index]) else { continue }
            setPrivateMode(mode, enabled: enabled)
            // Setting focus reporting, even again, reports the current focus.
            if mode == .sendFocus && enabled { replies += encode(.focus(isFocused)) }
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
        case .origin:
            modes.origin = enabled
            position(row: 0, column: 0)
            generation &+= 1
        case .wraparound: modes.wraparound = enabled
        case .reverseWraparound: modes.reverseWraparound = enabled
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
            // Each screen keeps its own region, and the cursor moves into the new one in origin mode.
            screen.setAlternate(enabled, style: style)
            if modes.origin { screen.moveIntoScrollRegion() }
            generation &+= 1
        case .bracketedPaste: modes.bracketedPaste = enabled
        case .synchronizedOutput:
            // The presenter owns the timeout. Parsing, input and replies continue during a batch.
            generation &+= 1
            modes.synchronizedOutputID = enabled ? generation : nil
        // Setting it sends nothing. A program asks with DECDSR 996 for the current appearance.
        case .reportAppearance: modes.reportAppearance = enabled
        }
    }
}
