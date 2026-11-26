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
        let marks = unsafeBitCast((offset | (offset &+ 33)) & 0x80, to: SIMD2<UInt64>.self)
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
    /// only when `continuingASCII` and a glyph came before it, so ASCII after a lone byte order mark
    /// takes the vector path. Returns how many glyphs it decoded and any C1 control that ended them.
    mutating func decodeText<let capacity: Int>(in bytes: Span<UInt8>, index: inout Int, continuingASCII: Bool,
                                                into buffer: inout InlineArray<capacity, UInt32>)
        -> (count: Int, control: Unicode.Scalar?) {
        var glyphs = buffer.mutableSpan
        // Working on copies keeps the position and state in registers, since the compiler can't
        // tell that writing a glyph leaves them alone.
        var decoder = self, position = index, count = 0
        var control: Unicode.Scalar?
        while count < glyphs.count, position < bytes.count {
            let byte = bytes[position]
            if byte < 0x80 {
                guard continuingASCII, count > 0, decoder.isComplete, Self.isPrintableASCII(byte) else { break }
                if bytes.count &- position >= 16, glyphs.count &- count >= 16 {
                    // A stretch of printable ASCII shorter than a block joins the text at once. A longer
                    // one ends it, since the vector path writes that faster.
                    let block = bytes.bytes.load(fromByteOffset: position, as: SIMD16<UInt8>.self)
                    let length = Self.printablePrefix(of: block)
                    guard length < 16 else { break }
                    var output = glyphs.mutableBytes
                    output.storeBytes(of: Self.widened(block), toByteOffset: count &* 4, as: SIMD16<UInt32>.self)
                    count &+= length
                    position &+= length
                    continue
                }
                glyphs[count] = UInt32(byte)
                count += 1
                position += 1
                continue
            }
            var sequence: (value: UInt32?, length: Int) = (nil, 0)
            if decoder.isComplete, bytes.count &- position >= 4 {
                // A branch for each length lets the next read start before this sequence's bytes arrive.
                switch byte {
                case 0xe0...0xef:
                    // CJK text comes in runs of three-byte sequences, so four decode at once when they can.
                    // It's all four or none, so the position advances by a fixed amount and the next read
                    // doesn't wait on these values.
                    if bytes.count &- position >= 16, glyphs.count &- count >= 4,
                       let values = Self.fourThreeByteSequences(in: bytes, at: position) {
                        var four = values
                        for lane in 0..<4 {
                            four[lane] = Terminal.StoredCell.glyph(values[lane], width: ColumnWidth.of(values[lane]))
                        }
                        var output = glyphs.mutableBytes
                        output.storeBytes(of: four, toByteOffset: count &* 4, as: SIMD4<UInt32>.self)
                        count &+= 4
                        position &+= 12
                        continue
                    }
                    sequence = (Self.sequence(in: bytes, at: position, length: 3), 3)
                case 0xc2...0xdf: sequence = (Self.sequence(in: bytes, at: position, length: 2), 2)
                case 0xf0...0xf4: sequence = (Self.sequence(in: bytes, at: position, length: 4), 4)
                default: break
                }
            }
            let value: UInt32
            if let decoded = sequence.value {
                value = decoded
                position &+= sequence.length
            } else {
                position += 1
                guard let decoded = decoder.decode(byte) else { continue }
                if decoded.value < 0xa0 {
                    control = decoded
                    break
                }
                value = decoded.value
            }
            if value == Self.byteOrderMark.value { continue }
            glyphs[count] = Terminal.StoredCell.glyph(value, width: ColumnWidth.of(value))
            count += 1
        }
        self = decoder
        index = position
        return (count, control)
    }

    /// Decodes a complete, valid, printable sequence of `length` bytes at `start`, from the four bytes
    /// there. Returns nil for a C1 control or an invalid sequence, which the byte-at-a-time decoder
    /// handles instead.
    @inline(__always)
    private static func sequence(in bytes: Span<UInt8>, at start: Int, length: Int) -> UInt32? {
        let word = UInt32(bigEndian: bytes.bytes.load(fromByteOffset: start, as: UInt32.self))
        // Each byte after the lead starts with 10.
        let following = 0x00c0_c0c0 & ~(UInt32.max >> (8 * length))
        guard word & following == 0x0080_8080 & following else { return nil }
        let bits = (word >> 24 & 0x7f >> length) << 18 | (word >> 16 & 0x3f) << 12 | (word >> 8 & 0x3f) << 6 | word & 0x3f
        let value = bits >> (6 * (4 - length))
        // A value a shorter sequence could encode is overlong, and two-byte values below 0xa0 are C1 controls.
        // Three bytes can also encode a UTF-16 surrogate, and four a value past the last scalar.
        switch length {
        case 2: guard value >= 0xa0 else { return nil }
        case 3: guard value >= 0x800, value & 0xf800 != 0xd800 else { return nil }
        default: guard value >= 0x1_0000, value <= 0x10_ffff else { return nil }
        }
        return value
    }

    /// Decodes four three-byte sequences in a row from the 16 bytes at `start`. Returns nil unless
    /// all four are valid and none is a byte order mark.
    @inline(__always)
    private static func fourThreeByteSequences(in bytes: Span<UInt8>, at start: Int) -> SIMD4<UInt32>? {
        let block = bytes.bytes.load(fromByteOffset: start, as: SIMD16<UInt8>.self)
        // Leads of 1110 at bytes 0, 3, 6 and 9, and bytes starting with 10 between them.
        let pattern = (unsafeBitCast(block, to: SIMD2<UInt64>.self) & SIMD2(0xc0f0_c0c0_f0c0_c0f0, 0xc0c0_f0c0))
            ^ SIMD2(0x80e0_8080_e080_80e0, 0x8080_e080)
        guard pattern[0] | pattern[1] == 0 else { return nil }
        // Each sequence's bytes, last first, make one little-endian lane.
        let b = block
        let lanes = unsafeBitCast(SIMD16(b[2], b[1], b[0], 0, b[5], b[4], b[3], 0, b[8], b[7], b[6], 0, b[11], b[10], b[9], 0),
                                  to: SIMD4<UInt32>.self)
        let values = lanes & 0x3f | lanes &>> 2 & 0xfc0 | lanes &>> 4 & 0xf000
        // A lane's top bit marks a value below 0x800, a UTF-16 surrogate or a byte order mark.
        let marks = (values &- 0x800) | ((values & 0xf800 ^ 0xd800) &- 1) | ((values ^ Self.byteOrderMark.value) &- 1)
        let halves = unsafeBitCast(marks, to: SIMD2<UInt64>.self)
        guard (halves[0] | halves[1]) & 0x8000_0000_8000_0000 == 0 else { return nil }
        return values
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
