/// Finds runs of printable ASCII in 16-byte blocks so the grid can write a run at once.
/// It also carries incomplete UTF-8 scalars across chunks. ThrushBench exercises this path
/// with a one-megabyte ASCII stream delivered in 4 KiB chunks.
struct TextScanner: Sendable {
    static let byteOrderMark: Unicode.Scalar = "\u{feff}"

    /// Space through tilde occupy exactly 95 consecutive ASCII positions.
    static func isPrintableASCII(_ value: some FixedWidthInteger & UnsignedInteger) -> Bool {
        value &- 0x20 < 95
    }

    /// The first non-printable or non-ASCII byte, or the end of the input.
    static func endOfASCII(in bytes: Span<UInt8>, from start: Int) -> Int {
        var index = start
        while bytes.count - index >= 16 {
            let length = printablePrefix(of: bytes.bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self))
            if length < 16 { return index + length }
            index += 16
        }
        while index < bytes.count && isPrintableASCII(bytes[index]) { index += 1 }
        return index
    }

    /// How many lanes of `block` are printable ASCII before the first that isn't.
    @inline(__always)
    private static func printablePrefix(of block: SIMD16<UInt8>) -> Int {
        // A lane is printable ASCII exactly when subtracting space gives a value below 95.
        // Adding 33 sets the high bit from 95 up, and anything past 127 has it already, so
        // the high bits mark the lanes that end the run.
        let offset = block &- 0x20
        let marks = bitCast((offset | (offset &+ 33)) & 0x80, to: SIMD2<UInt64>.self)
        // Each half read as a little-endian word puts its first lane in the lowest byte.
        let first = UInt64(littleEndian: marks[0]), second = UInt64(littleEndian: marks[1])
        if first != 0 { return first.trailingZeroBitCount / 8 }
        if second != 0 { return 8 + second.trailingZeroBitCount / 8 }
        return 16
    }

    /// Each byte of `block` as a 32-bit lane. Widening by halves compiles to a few vector instructions,
    /// where widening all 16 lanes at once compiles to a call.
    @inline(__always)
    private static func widened(_ block: SIMD16<UInt8>) -> SIMD16<UInt32> {
        let halves = SIMD16<UInt16>(lowHalf: .init(truncatingIfNeeded: block.lowHalf),
                                    highHalf: .init(truncatingIfNeeded: block.highHalf))
        return SIMD16<UInt32>(lowHalf: .init(truncatingIfNeeded: halves.lowHalf),
                              highHalf: .init(truncatingIfNeeded: halves.highHalf))
    }

    /// Decodes printable text from `index` into `buffer`, each a scalar with the flag for its width,
    /// until a control, the end of this chunk or a full buffer. Printable ASCII continues the text
    /// only after a glyph, so ASCII after a lone byte order mark takes the vector path. Returns how
    /// many glyphs it decoded, or the C1 control that came before any.
    mutating func decodeText<let capacity: Int>(in bytes: Span<UInt8>, index: inout Int,
                                                into buffer: inout InlineArray<capacity, UInt32>)
        -> (count: Int, control: Unicode.Scalar?) {
        var glyphs = buffer.mutableSpan
        var count = 0
        var control: Unicode.Scalar?
        while count < glyphs.count, index < bytes.count {
            let byte = bytes[index]
            if byte < 0x80 {
                guard count > 0, isComplete, Self.isPrintableASCII(byte) else { break }
                if bytes.count &- index >= 16, glyphs.count &- count >= 16 {
                    // A stretch of printable ASCII shorter than a block joins the text at once. A longer
                    // one ends it, since the vector path writes that faster.
                    let block = bytes.bytes.load(fromByteOffset: index, as: SIMD16<UInt8>.self)
                    let length = Self.printablePrefix(of: block)
                    guard length < 16 else { break }
                    var output = glyphs.mutableBytes
                    output.storeBytes(of: Self.widened(block), toByteOffset: count &* 4, as: SIMD16<UInt32>.self)
                    count &+= length
                    index &+= length
                    continue
                }
                glyphs[count] = UInt32(byte)
                count += 1
                index += 1
                continue
            }
            var sequence: (scalar: Unicode.Scalar?, length: Int) = (nil, 0)
            if isComplete, bytes.count &- index >= 4 {
                // A branch for each length lets the next read start before this sequence's bytes arrive.
                switch byte {
                case 0xc2...0xdf: sequence = (Self.sequence(in: bytes, at: index, length: 2), 2)
                case 0xe0...0xef: sequence = (Self.sequence(in: bytes, at: index, length: 3), 3)
                case 0xf0...0xf4: sequence = (Self.sequence(in: bytes, at: index, length: 4), 4)
                default: break
                }
            }
            let scalar: Unicode.Scalar
            if let decoded = sequence.scalar {
                scalar = decoded
                index &+= sequence.length
            } else {
                index += 1
                guard let decoded = decode(byte) else { continue }
                if decoded.value < 0xa0 {
                    // A C1 control after glyphs is read again on its own. Its two bytes are both in this chunk,
                    // since the glyphs before them are.
                    if count > 0 { index -= 2 } else { control = decoded }
                    break
                }
                scalar = decoded
            }
            if scalar == Self.byteOrderMark { continue }
            glyphs[count] = Terminal.StoredCell.glyph(scalar, width: ColumnWidth.of(scalar))
            count += 1
        }
        return (count, control)
    }

    /// The smallest value a sequence of each length encodes. A smaller one is an overlong form,
    /// and two-byte values below 0xa0 are C1 controls.
    private static let smallestValues: InlineArray<5, UInt32> = [0, 0, 0xa0, 0x800, 0x1_0000]

    /// Decodes a complete, valid, printable sequence of `length` bytes at `start`, from the four bytes
    /// there. Returns nil for a C1 control or an invalid sequence, which the byte-at-a-time decoder
    /// handles instead.
    @inline(__always)
    private static func sequence(in bytes: Span<UInt8>, at start: Int, length: Int) -> Unicode.Scalar? {
        let word = UInt32(bigEndian: bytes.bytes.load(fromByteOffset: start, as: UInt32.self))
        // Each byte after the lead starts with 10.
        let following = 0x00c0_c0c0 & ~(UInt32.max >> (8 * length))
        guard word & following == 0x0080_8080 & following else { return nil }
        let bits = (word >> 24 & 0x7f >> length) << 18 | (word >> 16 & 0x3f) << 12 | (word >> 8 & 0x3f) << 6 | word & 0x3f
        let value = bits >> (6 * (4 - length))
        guard value >= smallestValues[length] else { return nil }
        return Unicode.Scalar(value)
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
