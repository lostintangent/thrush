extension Terminal {
    public enum Input: Sendable {
        case text(String)
        case paste(String)
        case key(Key, modifiers: Modifiers = [])

        public enum Key: Sendable {
            case up, down, right, left, home, end, pageUp, pageDown, delete
            case enter, escape, backspace, tab
            /// A layout-resolved hardware key. Use text(_:) for committed text and composition.
            case character(Character)
        }

        /// Command belongs to native application shortcuts. These modifiers reach the terminal.
        public struct Modifiers: OptionSet, Sendable {
            public let rawValue: UInt8
            public init(rawValue: UInt8) { self.rawValue = rawValue }
            public static let shift = Self(rawValue: 1)
            public static let alt = Self(rawValue: 2)
            public static let control = Self(rawValue: 4)
        }
    }

    /// Encode local input under the current terminal modes. The shell supplies its own echo.
    public func encode(_ input: Input) -> [UInt8] {
        switch input {
        case .text(let text):
            return Array(text.utf8)
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
