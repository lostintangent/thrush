extension Terminal {
    /// A user action to encode with ``Terminal/encode(_:)`` under the current terminal modes.
    public enum Input: Sendable {
        /// Committed text, including the result of input-method composition, sent as UTF-8.
        case text(String)
        /// Pasted text. The encoder normalizes line endings to carriage returns and adds delimiters when the shell requests bracketed paste.
        case paste(String)
        /// A pointer action on the visible grid that the shell's mouse-tracking mode may report.
        case pointer(Pointer)
        /// A hardware or accessory key and its active terminal modifiers.
        case key(Key, modifiers: Modifiers = [])

        /// A key whose terminal sequence can depend on modifiers and the shell's current modes.
        public enum Key: Sendable {
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
            /// The Page Up key. Shift–Page Up scrolls the host viewport locally.
            case pageUp
            /// The Page Down key. Shift–Page Down scrolls the host viewport locally.
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
        /// Handle Command shortcuts in the host before forwarding input.
        public struct Modifiers: OptionSet, Sendable {
            /// The bit mask containing the active terminal modifiers.
            public let rawValue: UInt8
            /// Creates a modifier set from its bit mask. Use an array literal to combine named flags.
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            /// The Shift key.
            public static let shift = Self(rawValue: 1)
            /// The terminal Alt modifier, corresponding to Option on Apple keyboards.
            public static let alt = Self(rawValue: 2)
            /// The Control key.
            public static let control = Self(rawValue: 4)
        }
    }

    /// Returns the bytes to send for a user action under the current terminal modes.
    ///
    /// Send a nonempty result to the shell. The shell supplies the echo. An action
    /// handled locally or disabled by the active modes can produce an empty result.
    public func encode(_ input: Input) -> [UInt8] {
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
        }
    }

    private func encodeKey(_ key: Input.Key, modifiers: Input.Modifiers) -> [UInt8] {
        let parameter = UInt8(ascii: "1") + modifiers.rawValue
        func cursorKey(_ final: UInt8) -> [UInt8] {
            if modifiers.isEmpty { return [0x1b, modes.applicationCursorKeys ? 0x4f : 0x5b, final] }
            return [0x1b, 0x5b, 0x31, 0x3b, parameter, final]
        }
        func tildeKey(_ digit: UInt8, modified: Bool) -> [UInt8] {
            modified ? [0x1b, 0x5b, digit, 0x3b, parameter, 0x7e] : [0x1b, 0x5b, digit, 0x7e]
        }
        func scalarKey(_ byte: UInt8) -> [UInt8] { modifiers.contains(.alt) ? [0x1b, byte] : [byte] }

        switch key {
        case .up: return cursorKey(0x41)
        case .down: return cursorKey(0x42)
        case .right: return cursorKey(0x43)
        case .left: return cursorKey(0x44)
        case .home: return cursorKey(0x48)
        case .end: return cursorKey(0x46)
        case .delete: return tildeKey(0x33, modified: !modifiers.isEmpty)
        case .pageUp, .pageDown:
            // Shift+Page scrolls the host viewport without writing to the shell.
            guard !modifiers.contains(.shift) else { return [] }
            let digit: UInt8 = if case .pageUp = key { 0x35 } else { 0x36 }
            return tildeKey(digit, modified: modifiers.contains(.control))
        case .enter: return scalarKey(0x0d)
        case .escape: return scalarKey(0x1b)
        case .backspace: return scalarKey(modifiers.contains(.control) ? 0x08 : 0x7f)
        case .tab: return modifiers.contains(.shift) ? [0x1b, 0x5b, 0x5a] : [0x09]
        case .character(let character):
            return encodeCharacter(character, modifiers: modifiers)
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
