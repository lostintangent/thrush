/// Finds runs of printable ASCII in 16-byte blocks so the grid can write a run at once.
/// It also carries incomplete UTF-8 scalars across chunks. ThrushBench exercises this path
/// with a one-megabyte ASCII stream delivered in 4 KiB chunks.
struct TextScanner: Sendable {
    static let byteOrderMark: Unicode.Scalar = "\u{feff}"
    static let delete: Unicode.Scalar = "\u{7f}"

    /// Space through tilde occupy exactly 95 consecutive ASCII positions.
    static func isPrintableASCII(_ value: some FixedWidthInteger & UnsignedInteger) -> Bool {
        value &- 0x20 < 95
    }

    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        // Above the C1 controls, even a zero-width scalar belongs to the text stream.
        scalar.value >= 0xa0 || isPrintableASCII(scalar.value)
    }

    /// The first non-printable or non-ASCII byte, or the end of the input.
    static func endOfASCII(in bytes: Span<UInt8>, from start: Int) -> Int {
        var index = start
        while bytes.count - index >= 16 {
            // A lane is printable ASCII exactly when subtracting space gives a value below 95.
            // Adding 33 sets the high bit from 95 up, and anything past 127 has it already, so
            // the high bits mark the lanes that end the run.
            let offset = bytes.bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self) &- 0x20
            let marks = unsafeBitCast((offset | (offset &+ 33)) & 0x80, to: SIMD2<UInt64>.self)
            // Each half read as a little-endian word puts its first lane in the lowest byte.
            let first = UInt64(littleEndian: marks[0]), second = UInt64(littleEndian: marks[1])
            if first != 0 { return index + first.trailingZeroBitCount / 8 }
            if second != 0 { return index + 8 + second.trailingZeroBitCount / 8 }
            index += 16
        }
        while index < bytes.count && isPrintableASCII(bytes[index]) { index += 1 }
        return index
    }

    /// Returns the next decoded non-ASCII scalar before an ASCII byte or the end of this chunk.
    @inline(__always)
    mutating func nextNonASCII(in bytes: Span<UInt8>, index: inout Int) -> Unicode.Scalar? {
        while index < bytes.count, bytes[index] >= 0x80 {
            let byte = bytes[index]
            index += 1
            if let scalar = decode(byte), scalar != Self.byteOrderMark { return scalar }
        }
        return nil
    }

    private(set) var value: UInt32 = 0
    private(set) var remaining = 0
    private(set) var nextRange: ClosedRange<UInt8> = 0x80...0xbf

    var isComplete: Bool { remaining == 0 }

    @inline(__always)
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
