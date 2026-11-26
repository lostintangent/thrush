/// A control function by name, in the five families the standards define. Each family pairs every
/// function Thrush performs with its wire bytes, and the parser names a function by looking those up.
enum ControlFunction: Equatable {
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
        /// SO, 0x0E, prints with G1.
        case shiftOut = 0x0e
        /// SI, 0x0F, prints with G0.
        case shiftIn = 0x0f
    }

    enum Escape: UInt32 {
        /// DECSC, ESC 7.
        case saveCursor = 0x37
        /// DECRC, ESC 8.
        case restoreCursor = 0x38
        /// DECKPAM, ESC =.
        case applicationKeypad = 0x3d
        /// DECKPNM, ESC >.
        case numericKeypad = 0x3e
        /// IND, ESC D or C1 0x84.
        case index = 0x44
        /// NEL, ESC E or C1 0x85.
        case nextLine = 0x45
        /// HTS, ESC H or C1 0x88.
        case tabSet = 0x48
        /// RI, ESC M.
        case reverseIndex = 0x4d
        /// RIS, ESC c.
        case fullReset = 0x63
        /// LS2, ESC n, prints with G2.
        case lockingShift2 = 0x6e
        /// LS3, ESC o, prints with G3.
        case lockingShift3 = 0x6f
        /// LS3R, ESC |. Without a right half, the reference prints with G3 as LS3 does.
        case lockingShift3Right = 0x7c
        /// LS2R, ESC }, prints with G2.
        case lockingShift2Right = 0x7d
        /// LS1R, ESC ~, prints with G1.
        case lockingShift1Right = 0x7e
        /// DECALN, ESC # 8, fills the screen with E.
        case screenAlignmentPattern = 0x23_38
        /// DOCS, ESC % @, returns to ASCII in G0.
        case selectDefaultCharacterSet = 0x25_40
        /// DOCS, ESC % G. Input is always UTF-8, so this also returns to ASCII in G0.
        case selectUTF8 = 0x25_47

        /// The 8-bit forms of IND, NEL and HTS. The reference executes no other C1 control.
        init?(c1 byte: UInt8) {
            guard byte == 0x84 || byte == 0x85 || byte == 0x88 else { return nil }
            self.init(rawValue: UInt32(byte - 0x40))
        }
    }

    enum CSI: UInt32 {
        /// ICH, CSI Ps @.
        case insertCharacters = 0x40
        /// SL, CSI Ps SP @.
        case scrollLeft = 0x20_40
        /// CUU, CSI Ps A.
        case cursorUp = 0x41
        /// SR, CSI Ps SP A.
        case scrollRight = 0x20_41
        /// CUD, CSI Ps B.
        case cursorDown = 0x42
        /// CUF, CSI Ps C.
        case cursorForward = 0x43
        /// CUB, CSI Ps D.
        case cursorBackward = 0x44
        /// CNL, CSI Ps E.
        case cursorNextLine = 0x45
        /// CPL, CSI Ps F.
        case cursorPrecedingLine = 0x46
        /// CHA, CSI Ps G.
        case cursorColumn = 0x47
        /// CUP, CSI row ; column H.
        case cursorPosition = 0x48
        /// CHT, CSI Ps I.
        case forwardTab = 0x49
        /// ED, CSI Ps J.
        case eraseInDisplay = 0x4a
        /// DECSED, CSI ? Ps J. Without protected cells it erases as ED does.
        case selectiveEraseInDisplay = 0x3f_4a
        /// EL, CSI Ps K.
        case eraseInLine = 0x4b
        /// DECSEL, CSI ? Ps K. Without protected cells it erases as EL does.
        case selectiveEraseInLine = 0x3f_4b
        /// IL, CSI Ps L.
        case insertLines = 0x4c
        /// DL, CSI Ps M.
        case deleteLines = 0x4d
        /// DCH, CSI Ps P.
        case deleteCharacters = 0x50
        /// SU, CSI Ps S.
        case scrollUp = 0x53
        /// SD, CSI Ps T.
        case scrollDown = 0x54
        /// ECH, CSI Ps X.
        case eraseCharacters = 0x58
        /// CBT, CSI Ps Z.
        case backwardTab = 0x5a
        /// HPA, CSI Ps `.
        case columnAbsolute = 0x60
        /// HPR, CSI Ps a.
        case columnRelative = 0x61
        /// REP, CSI Ps b.
        case repeatPrecedingCharacter = 0x62
        /// DA1, CSI Ps c.
        case primaryDeviceAttributes = 0x63
        /// DA2, CSI > Ps c.
        case secondaryDeviceAttributes = 0x3e_63
        /// VPA, CSI Ps d.
        case rowAbsolute = 0x64
        /// VPR, CSI Ps e.
        case rowRelative = 0x65
        /// HVP, CSI row ; column f.
        case horizontalVerticalPosition = 0x66
        /// TBC, CSI Ps g.
        case tabClear = 0x67
        /// SM, CSI Pm h.
        case setMode = 0x68
        /// DECSET, CSI ? Pm h.
        case setPrivateMode = 0x3f_68
        /// RM, CSI Pm l.
        case resetMode = 0x6c
        /// DECRST, CSI ? Pm l.
        case resetPrivateMode = 0x3f_6c
        /// SGR, CSI Pm m.
        case graphicRendition = 0x6d
        /// DSR, CSI Ps n.
        case deviceStatusReport = 0x6e
        /// DECDSR, CSI ? Ps n.
        case privateDeviceStatusReport = 0x3f_6e
        /// DECSTR, CSI ! p.
        case softReset = 0x21_70
        /// DECRQM, CSI Ps $ p.
        case requestMode = 0x24_70
        /// DECRQM, CSI ? Ps $ p.
        case requestPrivateMode = 0x3f_24_70
        /// DECSCUSR, CSI Ps SP q.
        case cursorStyle = 0x20_71
        /// DECSTBM, CSI top ; bottom r.
        case scrollMargins = 0x72
        /// SCOSC, CSI s.
        case saveCursor = 0x73
        /// SCORC, CSI u.
        case restoreCursor = 0x75
        /// DECIC, CSI Ps ' }.
        case insertColumns = 0x27_7d
        /// DECDC, CSI Ps ' ~.
        case deleteColumns = 0x27_7e
    }

    enum OSC: Int {
        /// OSC 0 sets the icon name and window title. A shell presents only its title.
        case setIconAndWindowTitle = 0
        /// OSC 2 sets the window title.
        case setWindowTitle = 2
        /// OSC 4 sets or queries indexed colors.
        case indexedColor = 4
        /// OSC 8 makes the text after it a link, or ends the link with an empty URI.
        case hyperlink = 8
        /// OSC 10 sets or queries the default foreground, then the colors after it.
        case foregroundColor = 10
        /// OSC 11 sets or queries the default background, then the cursor color.
        case backgroundColor = 11
        /// OSC 12 sets or queries the cursor color.
        case cursorColor = 12
        /// OSC 52 copies text to the pasteboard.
        case clipboard = 52
        /// OSC 104 restores the listed indexed colors, or all of them.
        case restoreIndexedColors = 104
        /// OSC 110 restores the default foreground.
        case restoreForegroundColor = 110
        /// OSC 111 restores the default background.
        case restoreBackgroundColor = 111
        /// OSC 112 restores the cursor color.
        case restoreCursorColor = 112
    }

    /// Device control strings, named by their intermediates and final byte. Parameters are ignored.
    enum DCS: UInt32 {
        /// DECRQSS, DCS $ q, asks for the setting of the control function its payload names.
        case requestStatusString = 0x2471
        /// XTGETTCAP, DCS + q, asks for the terminal capabilities its payload names.
        case requestCapabilities = 0x2b71
    }

    case c0(C0)
    /// An escape function, including IND, NEL and HTS sent as C1 controls.
    case escape(Escape)
    /// SCS, ESC I F. The intermediate names the slot and the final names the set.
    case designate(Terminal.CharacterSet, slot: Int)
    /// Reads the parser's parameters.
    case csi(CSI)
    /// Reads the parser's payload.
    case osc(OSC)
    /// Reads the parser's payload.
    case dcs(DCS)
    /// Performs nothing, and still ends the text run.
    case unsupported

    /// A C0 control, or one of the three C1 controls the reference executes, named as its escape form.
    init(executing byte: UInt8) {
        if let function = C0(rawValue: byte) {
            self = .c0(function)
        } else if let function = Escape(c1: byte) {
            self = .escape(function)
        } else {
            self = .unsupported
        }
    }

    /// An escape function or a designation, from its intermediates and final byte packed in wire order.
    init(escape identifier: UInt32) {
        if let function = Escape(rawValue: identifier) {
            self = .escape(function)
        } else if let slot = Self.designatedSlot(identifier >> 8),
                  let set = Terminal.CharacterSet(final: UInt8(truncatingIfNeeded: identifier)) {
            self = .designate(set, slot: slot)
        } else {
            self = .unsupported
        }
    }

    /// A control sequence, from its private marker, intermediates and final byte packed in wire order.
    init(csi identifier: UInt32) {
        self = CSI(rawValue: identifier).map(Self.csi) ?? .unsupported
    }

    /// The slot an SCS intermediate designates into. The reference ignores `/`, which names a 96-character G3.
    private static func designatedSlot(_ intermediates: UInt32) -> Int? {
        switch intermediates {
        case 0x28: 0  // (
        case 0x29, 0x2d: 1  // ) and -
        case 0x2a, 0x2e: 2  // * and .
        case 0x2b: 3  // +
        default: nil
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
        static func cursorPosition(row: Int, column: Int) -> String {
            "\u{1b}[\(row + 1);\(column + 1)R"
        }

        /// DECXCPR answers DECDSR 6 with the same coordinates as CPR.
        static func privateCursorPosition(row: Int, column: Int) -> String {
            "\u{1b}[?\(row + 1);\(column + 1)R"
        }

        /// DSR 5 reports that the terminal is working.
        static let operatingStatus = "\u{1b}[0n"

        /// DSR 997 answers DECDSR 996 and reports each change while mode 2031 is set.
        static func appearance(_ appearance: Appearance) -> String {
            "\u{1b}[?997;\(appearance.rawValue)n"
        }

        /// DECRPM answers DECRQM with the mode number and its state.
        static func modeReport(_ mode: Int, _ state: ModeState, isPrivate: Bool) -> String {
            "\u{1b}[\(isPrivate ? "?" : "")\(mode);\(state.rawValue)$y"
        }

        /// DECRPSS answers DECRQSS with the control function that restores the setting the payload names,
        /// or with 0 when it names none the terminal reports.
        static func statusString(_ payload: String, style: Style, cursorStyle: CursorStyleParameter,
                                 scrollTop: Int, scrollBottom: Int) -> String {
            let setting: String? = switch payload {
            // No cell is protected from selective erase.
            case "\"q": "0\"q"
            // A VT100-level terminal that sends 7-bit controls, matching DA1.
            case "\"p": "61;1\"p"
            case "r": "\(scrollTop + 1);\(scrollBottom + 1)r"
            case "m": "\(style.renditionParameters)m"
            case " q": "\(cursorStyle.rawValue) q"
            default: nil
            }
            return setting.map { "\u{1b}P1$r\($0)\u{1b}\\" } ?? "\u{1b}P0$r\u{1b}\\"
        }

        /// XTGETTCAP names capabilities in hex, separated by semicolons. The terminal answers only Ms, which
        /// tells a program it can copy with OSC 52, and leaves every other name unanswered, as Ghostty does.
        static func capabilities(_ payload: String) -> String {
            // Ms is `ESC ] 52 ; %p1%s ; %p2%s BEL`, which takes the selections and then the text.
            payload.split(separator: ";").filter { $0.lowercased() == "4d73" }.map { name in
                "\u{1b}P1+r\(name)=1B5D35323B25703125733B257032257307\u{1b}\\"
            }.joined()
        }
    }

    /// The states DECRPM can report for a mode.
    enum ModeState: Int {
        case unrecognized = 0, set, reset, permanentlySet, permanentlyReset

        init(_ enabled: Bool) { self = enabled ? .set : .reset }
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

        init(_ shape: CursorShape, blinking: Bool) {
            self = switch (shape, blinking) {
            case (.block, true): .blinkingBlock
            case (.block, false): .steadyBlock
            case (.underline, true): .blinkingUnderline
            case (.underline, false): .steadyUnderline
            case (.bar, true): .blinkingBar
            case (.bar, false): .steadyBar
            }
        }
    }

    enum EraseRange: Int {
        case toEnd = 0
        case toCursor = 1
        case entire = 2
    }

    enum Mode: Int {
        case insert = 4
        case newLine = 20
    }

    enum PrivateMode: Int {
        case applicationCursorKeys = 1
        /// DECANM. Without a VT52 mode to leave, setting it only designates ASCII into every slot.
        case ansi = 2
        case origin = 6
        case wraparound = 7
        case cursorBlink = 12
        case reverseWraparound = 45
        case cursorVisible = 25
        /// Switches screens without saving the cursor or clearing the alternate screen first.
        case alternateScreenOnly = 47
        case applicationKeypad = 66
        case mousePress = 1000
        case mouseDrag = 1002
        case mouseMotion = 1003
        case sendFocus = 1004
        case mouseSGR = 1006
        /// Behaves as 47 in the reference.
        case alternateScreenClearing = 1047
        case saveCursor = 1048
        case alternateScreen = 1049
        case bracketedPaste = 2004
        case synchronizedOutput = 2026
        /// Reports when the app's theme turns dark or light.
        case reportAppearance = 2031
    }
}
