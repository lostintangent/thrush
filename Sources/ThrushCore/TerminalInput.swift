// Encodes committed text, pasted text and keystrokes as input for the shell.
// The active terminal modes and keyboard modifiers determine which bytes a key sends.

extension Terminal {
    /// A user action to encode with ``Terminal/encode(_:)`` under the current terminal modes.
    package enum Input: Sendable {
        /// Committed text, including the result of input-method composition, sent as UTF-8.
        case text(String)
        /// Pasted text. The encoder normalizes line endings to carriage returns and adds delimiters when the shell requests bracketed paste.
        case paste(String)
        /// A pointer action on the visible grid that the shell's mouse-tracking mode may report.
        case pointer(Pointer)
        /// A hardware or accessory key and its active terminal modifiers.
        case key(Key, modifiers: Modifiers = [])
        /// Whether the app now shows the terminal with keyboard focus, reported while the program sets mode 1004.
        case focus(Bool)
        /// The app's theme turned dark or light, reported while the program sets mode 2031.
        case appearance(Appearance)

        /// A key whose terminal sequence can depend on modifiers and the shell's current modes.
        package enum Key: Sendable {
            /// The Up Arrow key.
            case up
            /// The Down Arrow key.
            case down
            /// The Right Arrow key.
            case right
            /// The Left Arrow key.
            case left
            /// The Home key.
            case home
            /// The End key.
            case end
            /// The Page Up key. Shift–Page Up scrolls the app's viewport locally.
            case pageUp
            /// The Page Down key. Shift–Page Down scrolls the app's viewport locally.
            case pageDown
            /// The forward Delete key.
            case delete
            /// The Return or Enter key.
            case enter
            /// The Escape key.
            case escape
            /// The Backspace key, labeled Delete on Mac keyboards.
            case backspace
            /// The Tab key, including backtab when combined with Shift.
            case tab
            /// The Insert key, which Mac keyboards label Help. Shift–Insert and Control–Insert are left to the app.
            case insert
            /// A function key from F1 through F12.
            case function(Int)
            /// A character from the active keyboard layout, for chords such as Control-C.
            ///
            /// Use ``Terminal/Input/text(_:)`` for a text system's committed string.
            case character(Character)
        }

        /// Keyboard modifiers used in terminal key and pointer reports.
        ///
        /// Handle Command shortcuts in the app before forwarding input.
        package struct Modifiers: OptionSet, Sendable {
            /// The bit mask containing the active terminal modifiers.
            package let rawValue: UInt8
            /// Creates a modifier set from its bit mask. Use an array literal to combine named flags.
            package init(rawValue: UInt8) { self.rawValue = rawValue }
            /// The Shift key.
            package static let shift = Self(rawValue: 1)
            /// The terminal Alt modifier, corresponding to Option on Apple keyboards.
            package static let alt = Self(rawValue: 2)
            /// The Control key.
            package static let control = Self(rawValue: 4)
        }
    }

    /// Returns the bytes to send for a user action under the current terminal modes.
    ///
    /// Send a nonempty result to the shell. The shell supplies the echo. An action
    /// handled locally or disabled by the active modes can produce an empty result.
    package func encode(_ input: Input) -> [UInt8] {
        switch input {
        case .text(let text):
            return Array(text.utf8)
        case .pointer(let event): return encodePointer(event)
        case .paste(let text):
            var bytes: [UInt8] = []
            if modes.bracketedPaste { bytes.append(contentsOf: "\u{1b}[200~".utf8) }
            var previous: UInt8?
            for byte in text.utf8 {
                if byte == 0x0a {
                    if previous != 0x0d { bytes.append(0x0d) }
                } else {
                    bytes.append(byte)
                }
                previous = byte
            }
            if modes.bracketedPaste { bytes.append(contentsOf: "\u{1b}[201~".utf8) }
            return bytes
        case .key(let key, let modifiers):
            return encodeKey(key, modifiers: modifiers.intersection([.shift, .alt, .control]))
        case .focus(let focused):
            guard modes.sendFocus else { return [] }
            return [0x1b, 0x5b, focused ? UInt8(ascii: "I") : UInt8(ascii: "O")]
        case .appearance(let appearance):
            guard modes.reportAppearance else { return [] }
            return Array(Reply.appearance(appearance).utf8)
        }
    }

    func encodeKey(_ key: Input.Key, modifiers: Input.Modifiers) -> [UInt8] {
        let disambiguate = keyboard.top.contains(.disambiguate)
        func scalar(_ byte: UInt8) -> [UInt8] { modifiers.contains(.alt) ? [0x1b, byte] : [byte] }

        func report(_ sequence: KeySequence) -> [UInt8] {
            if disambiguate { return sequence.disambiguated.encode(applicationCursorKeys: false, modifiers: modifiers) }
            return sequence.encode(applicationCursorKeys: modes.applicationCursorKeys, modifiers: modifiers)
        }
        // Unmodified, these keep their legacy bytes, so a shell left with flags by a program that
        // crashed still runs what's typed.
        func reportIfModified(_ code: UInt32, otherwise legacy: [UInt8]) -> [UInt8] {
            disambiguate && !modifiers.isEmpty ? Self.keyReport(code, modifiers: modifiers) : legacy
        }
        switch key {
        case .up: return report(.cursor(UInt8(ascii: "A")))
        case .down: return report(.cursor(UInt8(ascii: "B")))
        case .right: return report(.cursor(UInt8(ascii: "C")))
        case .left: return report(.cursor(UInt8(ascii: "D")))
        case .home: return report(.cursor(UInt8(ascii: "H")))
        case .end: return report(.cursor(UInt8(ascii: "F")))
        case .insert: return report(.numbered(2, modifyOn: [], localOn: [.shift, .control]))
        case .delete: return report(.numbered(3))
        case .pageUp: return report(.numbered(5, modifyOn: .control, localOn: .shift))
        case .pageDown: return report(.numbered(6, modifyOn: .control, localOn: .shift))
        case .function(let number):
            guard let sequence = KeySequence.function(number) else { return [] }
            return report(sequence)
        case .enter: return reportIfModified(13, otherwise: scalar(0x0d))
        case .escape: return disambiguate ? Self.keyReport(27, modifiers: modifiers) : scalar(0x1b)
        case .backspace: return reportIfModified(127, otherwise: scalar(modifiers.contains(.control) ? 0x08 : 0x7f))
        case .tab: return reportIfModified(9, otherwise: modifiers.contains(.shift) ? [0x1b, 0x5b, 0x5a] : [0x09])
        case .character(let character): return encodeCharacter(character, modifiers: modifiers)
        }
    }

    /// A kitty key report, `CSI code u`, with the shifted key after a colon and the modifiers after a semicolon.
    static func keyReport(_ code: UInt32, shifted: UInt32? = nil, modifiers: Input.Modifiers) -> [UInt8] {
        var report = "\u{1b}[\(code)"
        if let shifted { report += ":\(shifted)" }
        if !modifiers.isEmpty { report += ";\(modifiers.rawValue + 1)" }
        return Array((report + "u").utf8)
    }

    /// The wire sequence for a cursor, function or numbered editing key.
    enum KeySequence {
        case cursor(UInt8)
        case ss3(UInt8)
        /// Local modifiers consume the key. A matching reporting modifier includes the whole chord.
        case numbered(UInt8, modifyOn: Input.Modifiers = [.shift, .alt, .control], localOn: Input.Modifiers = [])

        /// F1 to F4 send SS3 like the keypad, and F5 to F12 are numbered with gaps from the VT220's keyboard.
        static func function(_ number: Int) -> Self? {
            switch number {
            case 1...4: .ss3(Array("PQRS".utf8)[number - 1])
            case 5...12: .numbered([15, 17, 18, 19, 20, 21, 23, 24][number - 5])
            default: nil
            }
        }

        /// The kitty protocol reports every modifier, except those the app keeps, and sends F1 to F4 as
        /// CSI. F3 becomes numbered, because `CSI 1 ; 2 R` would read as a cursor position report.
        var disambiguated: Self {
            switch self {
            case .cursor: self
            case .ss3(UInt8(ascii: "R")): .numbered(13)
            case .ss3(let final): .cursor(final)
            case .numbered(let number, _, let localOn): .numbered(number, localOn: localOn)
            }
        }

        func encode(applicationCursorKeys: Bool, modifiers: Input.Modifiers) -> [UInt8] {
            func csi(_ number: UInt8, final: UInt8, modifiers: Input.Modifiers) -> [UInt8] {
                let digit = UInt8(ascii: "0") + number % 10
                let modifier = UInt8(ascii: "1") + modifiers.rawValue
                // Construct the common one-digit report in one allocation.
                var bytes: [UInt8] = modifiers.isEmpty
                    ? [0x1b, 0x5b, digit, final]
                    : [0x1b, 0x5b, digit, 0x3b, modifier, final]
                if number >= 10 { bytes.insert(contentsOf: String(number / 10).utf8, at: 2) }
                return bytes
            }

            func letter(_ final: UInt8, ss3: Bool) -> [UInt8] {
                if modifiers.isEmpty { return [0x1b, ss3 ? 0x4f : 0x5b, final] }
                return csi(1, final: final, modifiers: modifiers)
            }

            switch self {
            case .cursor(let final): return letter(final, ss3: applicationCursorKeys)
            case .ss3(let final): return letter(final, ss3: true)
            case .numbered(let number, let modifyOn, let localOn):
                guard modifiers.isDisjoint(with: localOn) else { return [] }
                let wireModifiers: Input.Modifiers = modifiers.isDisjoint(with: modifyOn) ? [] : modifiers
                return csi(number, final: UInt8(ascii: "~"), modifiers: wireModifiers)
            }
        }
    }

    private func encodeCharacter(_ character: Character, modifiers: Input.Modifiers) -> [UInt8] {
        // Shift alone types the shifted text, as it does under the kitty protocol.
        if modifiers.isDisjoint(with: [.control, .alt]) { return Array(String(character).utf8) }
        if let report = keyReport(character, modifiers: modifiers) { return report }
        // Option is Meta, sending Escape before the chord without it. Text that Option composes, as
        // the Mac keyboard does by default, reaches the terminal as text instead.
        if modifiers.contains(.alt) {
            let chord = encodeCharacter(character, modifiers: modifiers.subtracting(.alt))
            return chord.isEmpty ? [] : [0x1b] + chord
        }
        guard let ascii = character.asciiValue else { return [] }
        if modifiers == .control {
            switch ascii {
            case 0x41...0x5a: return [ascii - 0x40]
            case 0x61...0x7a: return [ascii - 0x60]
            case 0x20: return [0]
            case 0x33...0x37: return [ascii - 0x33 + 0x1b]
            case 0x38: return [0x7f]
            case 0x5b...0x5d: return [ascii - 0x40]
            default: return []
            }
        }
        switch character {
        case "@": return [0]
        case "_": return [0x1f]
        default: return []
        }
    }

    /// The kitty protocol names a character key by its unshifted code. With alternate keys, a chord that
    /// holds Shift adds the shifted key, and those chords are reported even without disambiguation.
    private func keyReport(_ character: Character, modifiers: Input.Modifiers) -> [UInt8]? {
        func scalar(_ text: String) -> UInt32? {
            text.unicodeScalars.count == 1 ? text.unicodeScalars.first?.value : nil
        }
        let flags = keyboard.top
        guard !flags.isEmpty, let code = scalar(character.lowercased()) else { return nil }
        var shifted: UInt32?
        if flags.contains(.alternateKeys), modifiers.contains(.shift),
           let upper = scalar(character.uppercased()), upper != code {
            shifted = upper
        }
        guard flags.contains(.disambiguate) || shifted != nil else { return nil }
        return Self.keyReport(code, shifted: shifted, modifiers: modifiers)
    }
}
