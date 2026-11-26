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
        func scalar(_ byte: UInt8) -> [UInt8] { modifiers.contains(.alt) ? [0x1b, byte] : [byte] }

        func report(_ sequence: KeySequence) -> [UInt8] {
            sequence.encode(applicationCursorKeys: modes.applicationCursorKeys, modifiers: modifiers)
        }
        switch key {
        case .up: return report(.cursor(UInt8(ascii: "A")))
        case .down: return report(.cursor(UInt8(ascii: "B")))
        case .right: return report(.cursor(UInt8(ascii: "C")))
        case .left: return report(.cursor(UInt8(ascii: "D")))
        case .home: return report(.cursor(UInt8(ascii: "H")))
        case .end: return report(.cursor(UInt8(ascii: "F")))
        case .delete: return report(.numbered(3))
        case .pageUp: return report(.numbered(5, modifyOn: .control, localOn: .shift))
        case .pageDown: return report(.numbered(6, modifyOn: .control, localOn: .shift))
        case .enter: return scalar(0x0d)
        case .escape: return scalar(0x1b)
        case .backspace: return scalar(modifiers.contains(.control) ? 0x08 : 0x7f)
        case .tab: return modifiers.contains(.shift) ? [0x1b, 0x5b, 0x5a] : [0x09]
        case .character(let character): return encodeCharacter(character, modifiers: modifiers)
        }
    }

    /// The wire sequence for a cursor, function or numbered editing key.
    enum KeySequence {
        case cursor(UInt8)
        case ss3(UInt8)
        /// Local modifiers consume the key. A matching reporting modifier includes the whole chord.
        case numbered(UInt8, modifyOn: Input.Modifiers = [.shift, .alt, .control], localOn: Input.Modifiers = [])

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
        if !modifiers.contains(.control) {
            // With the macOS Option-key default, native text input supplies the composed character.
            return modifiers.contains(.alt) ? [] : Array(String(character).utf8)
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
}
