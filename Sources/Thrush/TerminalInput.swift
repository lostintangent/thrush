extension Terminal {
    public enum Input: Sendable {
        case text(String)
        case paste(String)
        case key(Key)

        public enum Key: Sendable {
            case up, down, right, left, enter, escape, backspace, tab
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
        case .key(let key):
            let prefix: UInt8 = modes.applicationCursorKeys ? 0x4f : 0x5b
            switch key {
            case .up: return [0x1b, prefix, 0x41]
            case .down: return [0x1b, prefix, 0x42]
            case .right: return [0x1b, prefix, 0x43]
            case .left: return [0x1b, prefix, 0x44]
            case .enter: return [0x0d]
            case .escape: return [0x1b]
            case .backspace: return [0x7f]
            case .tab: return [0x09]
            }
        }
    }
}
