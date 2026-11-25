/// Finds runs of printable ASCII in 16-byte blocks so the grid can write a run at once.
/// It also carries incomplete UTF-8 scalars across chunks. ThrushBench exercises this path
/// with a one-megabyte ASCII stream delivered in 4 KiB chunks.
struct TextScanner: Sendable {
    /// The first non-printable or non-ASCII byte, or the end of the input.
    /// A lane is printable ASCII exactly when subtracting space gives a value below 95.
    static func endOfASCII(in bytes: Span<UInt8>, from start: Int) -> Int {
        var index = start
        while bytes.count - index >= 16 {
            let block = bytes.bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self)
            if (block &- 0x20).max() >= 95 { break }
            index += 16
        }
        while index < bytes.count && bytes[index] &- 0x20 < 95 { index += 1 }
        return index
    }

    private var value: UInt32 = 0
    private var remaining = 0
    private var nextRange: ClosedRange<UInt8> = 0x80...0xbf

    var isComplete: Bool { remaining == 0 }

    mutating func decode(_ byte: UInt8) -> Unicode.Scalar? {
        if remaining > 0 && !nextRange.contains(byte) { self = Self() }
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
            return nil
        }
        return nil
    }
}
