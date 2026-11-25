/// A streaming UTF-8 decoder. Apply the Unicode maximal-subpart replacement rule,
/// including when a malformed prefix and the next valid byte arrive in separate chunks.
struct ScalarDecoder: Sendable {
    private var value: UInt32 = 0
    private var remaining = 0
    private var nextRange: ClosedRange<UInt8> = 0x80...0xbf

    func needsReplacement(before byte: UInt8) -> Bool {
        remaining > 0 && !nextRange.contains(byte)
    }

    mutating func decode(_ byte: UInt8) -> Unicode.Scalar? {
        if remaining > 0 {
            value = (value << 6) | UInt32(byte & 0x3f)
            remaining -= 1
            nextRange = 0x80...0xbf
            return remaining == 0 ? Unicode.Scalar(value) : nil
        }

        switch byte {
        case 0x00...0x7f:
            return Unicode.Scalar(byte)
        case 0xc2...0xdf:
            value = UInt32(byte & 0x1f)
            remaining = 1
        case 0xe0...0xef:
            value = UInt32(byte & 0x0f)
            remaining = 2
            if byte == 0xe0 { nextRange = 0xa0...0xbf }
            if byte == 0xed { nextRange = 0x80...0x9f }
        case 0xf0...0xf4:
            value = UInt32(byte & 0x07)
            remaining = 3
            if byte == 0xf0 { nextRange = 0x90...0xbf }
            if byte == 0xf4 { nextRange = 0x80...0x8f }
        default:
            return "\u{fffd}"
        }
        return nil
    }
}
