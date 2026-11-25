/// Names the wire identifiers for supported terminal functions. Dispatch uses those names
/// to connect each control sequence to its effect on the screen, modes or replies.
enum TerminalControlFunction {
    enum C0: UInt8 {
        /// BS, 0x08.
        case backspace = 0x08
        /// HT, 0x09.
        case horizontalTab = 0x09
        /// LF, 0x0A.
        case lineFeed = 0x0a
        /// VT, 0x0B.
        case verticalTab = 0x0b
        /// FF, 0x0C.
        case formFeed = 0x0c
        /// CR, 0x0D.
        case carriageReturn = 0x0d
    }

    enum Escape: UInt32 {
        /// DECKPAM, ESC =.
        case applicationKeypad = 0x3d
        /// DECKPNM, ESC >.
        case numericKeypad = 0x3e
    }

    enum CSI: UInt32 {
        /// ICH, CSI Ps @.
        case insertCharacters = 0x40
        /// CUU, CSI Ps A.
        case cursorUp = 0x41
        /// CUD, CSI Ps B.
        case cursorDown = 0x42
        /// CUF, CSI Ps C.
        case cursorForward = 0x43
        /// CUB, CSI Ps D.
        case cursorBackward = 0x44
        /// CUP, CSI row ; column H.
        case cursorPosition = 0x48
        /// ED, CSI Ps J.
        case eraseInDisplay = 0x4a
        /// EL, CSI Ps K.
        case eraseInLine = 0x4b
        /// DCH, CSI Ps P.
        case deleteCharacters = 0x50
        /// DA1, CSI Ps c.
        case primaryDeviceAttributes = 0x63
        /// DA2, CSI > Ps c.
        case secondaryDeviceAttributes = 0x3e_63
        /// DECSET, CSI ? Pm h.
        case setPrivateMode = 0x3f_68
        /// DECRST, CSI ? Pm l.
        case resetPrivateMode = 0x3f_6c
        /// SGR, CSI Pm m.
        case graphicRendition = 0x6d
        /// DSR, CSI Ps n.
        case deviceStatusReport = 0x6e
        /// DECRQM, CSI ? Ps $ p.
        case requestPrivateMode = 0x3f_24_70
        /// DECSCUSR, CSI Ps SP q.
        case cursorStyle = 0x20_71
        /// DECSTBM, CSI top ; bottom r.
        case scrollMargins = 0x72
    }

    enum OSC: Int {
        /// OSC 0 sets the icon name and window title. A shell presents only its title.
        case setIconAndWindowTitle = 0
        /// OSC 2 sets the window title.
        case setWindowTitle = 2
        /// OSC 4, indexed colors.
        case indexedColor = 4
        /// OSC 10, default foreground.
        case foregroundColor = 10
        /// OSC 11, default background.
        case backgroundColor = 11
    }

    case execute(C0)
    case escape(Escape)
    case control(CSI)
    case command(OSC)
    case ignoredString, stringPut(Unicode.Scalar), stringEnd(success: Bool)

    init?(_ action: EscapeParser.Action) {
        switch action {
        case .execute(let byte):
            guard let function = C0(rawValue: byte) else { return nil }
            self = .execute(function)
        case .esc(let id):
            guard let function = Escape(rawValue: id.rawValue) else { return nil }
            self = .escape(function)
        case .csi(let id):
            guard let function = CSI(rawValue: id.rawValue) else { return nil }
            self = .control(function)
        case .oscStart(let id):
            self = OSC(rawValue: id).map(Self.command) ?? .ignoredString
        case .dcsStart:
            self = .ignoredString
        case .stringPut(let scalar):
            self = .stringPut(scalar)
        case .stringEnd(let success):
            self = .stringEnd(success: success)
        case .printable:
            return nil
        }
    }
}

extension Terminal {
    /// Replies use the protocol identity expected by programs querying the terminal.
    enum Reply {
        /// DA1 identifies a VT100 with the Advanced Video Option.
        static let primaryDeviceAttributes = "\u{1b}[?1;2c"
        /// DA2 reports terminal type 0 (VT100), firmware version 276 and ROM cartridge 0.
        static let secondaryDeviceAttributes = "\u{1b}[>0;276;0c"

        /// CPR reports the cursor's row and column using the protocol's one-based coordinates.
        // Keep interpolation in the caller on query-heavy streams.
        @inline(__always)
        static func cursorPosition(row: Int, column: Int) -> String {
            "\u{1b}[\(row + 1);\(column + 1)R"
        }

        /// DECRPM reports private mode 12 as set (1) or reset (2).
        static func cursorBlink(enabled: Bool) -> String {
            enabled ? "\u{1b}[?12;1$y" : "\u{1b}[?12;2$y"
        }
    }

    /// DECSCUSR pairs each cursor shape with a blinking or steady presentation.
    enum CursorStyleParameter: Int {
        case defaultStyle = 0, blinkingBlock, steadyBlock, blinkingUnderline, steadyUnderline, blinkingBar, steadyBar

        var shape: CursorShape {
            switch self {
            case .defaultStyle, .blinkingBlock, .steadyBlock: .block
            case .blinkingUnderline, .steadyUnderline: .underline
            case .blinkingBar, .steadyBar: .bar
            }
        }
    }

    enum EraseRange: Int {
        case toEnd = 0
        case toCursor = 1
        case entire = 2
    }

    enum PrivateMode: Int {
        case applicationCursorKeys = 1
        case cursorBlink = 12
        case cursorVisible = 25
        case applicationKeypad = 66
        case mousePress = 1000
        case mouseDrag = 1002
        case mouseMotion = 1003
        case sendFocus = 1004
        case mouseSGR = 1006
        case alternateScreen = 1049
        case bracketedPaste = 2004
        case synchronizedOutput = 2026
    }
}
