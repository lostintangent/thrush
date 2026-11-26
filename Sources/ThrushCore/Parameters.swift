/// A control sequence's parameters: numbers separated by semicolons, each of which can carry colon
/// subparameters, as in `38:2::255:128:0;1`. They're kept as the bytes that arrived and read when a
/// function asks for them, so a header reads the same whether it came whole or split across reads.
struct Parameters: Sendable, CustomStringConvertible {
    private typealias Storage = InlineArray<1024, UInt8>
    /// Readers take at most 32 parameters, and 32 subparameters across the whole header.
    static let limit = 32
    static let semicolon = UInt8(ascii: ";")
    static let colon = UInt8(ascii: ":")

    private var storage = Storage(repeating: 0)
    private var length = 0
    /// A whole SGR header, left in the chunk it arrived in rather than copied.
    private var lent: Range<Int>?

    /// The number of parameters, counting the empty one after a trailing semicolon.
    var count: Int {
      mutating get {
        withBytes { bytes in
            var count = 1
            for index in bytes.indices where bytes[index] == Self.semicolon { count += 1 }
            return min(count, Self.limit)
        }
      }
    }

    /// Both omitted and zero parameters select the control function's default.
    @inline(__always)
    subscript(_ index: Int, default fallback: Int = 0) -> Int {
      mutating get {
        guard index < Self.limit else { return fallback }
        return withBytes { bytes in
            var position = 0
            for _ in 0..<index {
                while position < bytes.count, bytes[position] != Self.semicolon { position += 1 }
                guard position < bytes.count else { return fallback }
                position += 1
            }
            let value = Self.number(in: bytes, at: &position) ?? 0
            return value == 0 ? fallback : value
        }
      }
    }

    /// Lends the digits, colons and semicolons for a reader that takes the numbers in order.
    @inline(__always)
    mutating func withBytes<Result>(_ body: (Span<UInt8>) -> Result) -> Result {
        body(storage.span.extracting(0..<length))
    }

    /// Lends the header from the chunk it arrived in, when it was lent, and only receive's SGR reads it.
    @inline(__always)
    mutating func withBytes<Result>(in chunk: Span<UInt8>, _ body: (Span<UInt8>) -> Result) -> Result {
        if let lent { return body(chunk.extracting(lent)) }
        return withBytes(body)
    }

    /// Reads the number at `index`, saturating at `Int32.max`. An omitted number is nil.
    @inline(__always)
    static func number(in bytes: Span<UInt8>, at index: inout Int) -> Int? {
        guard index < bytes.count, bytes[index] <= UInt8(ascii: "9") else { return nil }
        var value = 0
        repeat {
            // Saturating at every digit keeps the value far from overflow.
            value = min(Int(Int32.max), value &* 10 &+ Int(bytes[index] &- UInt8(ascii: "0")))
            index += 1
        } while index < bytes.count && bytes[index] <= UInt8(ascii: "9")
        return value
    }

    /// The parameters as they'd be written on the wire.
    var description: String {
        var copy = self
        return copy.withBytes { bytes in String(decoding: bytes.indices.map { bytes[$0] }, as: UTF8.self) }
    }

    mutating func removeAll() {
        length = 0
        lent = nil
    }

    /// Leaves a whole header in the chunk it arrived in, for a reader that comes before the chunk changes.
    mutating func lend(_ range: Range<Int>) { lent = range }

    /// Accepts the parameter bytes 0x30–0x3B after the parser has consumed any prefix.
    @inline(__always)
    mutating func append(_ byte: UInt8) {
        if length == Storage.count { compact() }
        storage[length] = byte
        length += 1
    }

    /// Copies a run of `bytes`. Most headers are 16 bytes or less and take one load and one store,
    /// whose bytes past the run the length hides. A run near the end of a read, or a longer one, is
    /// copied a byte at a time, and only a header past 1 KiB compacts.
    @inline(__always)
    mutating func append(_ range: Range<Int>, of bytes: Span<UInt8>) {
        if range.count <= 16, bytes.count &- range.lowerBound >= 16, length <= Storage.count &- 16 {
            var span = storage.mutableSpan
            var output = span.mutableBytes
            output.storeBytes(of: bytes.bytes.load(fromByteOffset: range.lowerBound, as: SIMD16<UInt8>.self),
                              toByteOffset: length, as: SIMD16<UInt8>.self)
            length &+= range.count
        } else if range.count <= Storage.count &- length {
            for index in range {
                storage[length] = bytes[index]
                length &+= 1
            }
        } else {
            for index in range { append(bytes[index]) }
        }
    }

    /// Drops what no reader can see, so a header of any length fits: leading zeros, digits past the
    /// eleventh, which already saturate, and fields past the limits. At most 864 bytes remain (64
    /// numbers of up to 12 digits, 32 semicolons and 64 colons), and any bytes that follow read as
    /// they would have after the original ones.
    private mutating func compact() {
        var kept = 0
        var parameters = 1
        var subparameters = 0
        var digits = 0
        var keptZero = false
        // A subparameter past the limit keeps its colon, so digits that follow still land in it.
        var keepsDigits = true
        var markedPastLimit = false
        func keep(_ byte: UInt8) {
            storage[kept] = byte
            kept += 1
        }
        scan: for index in 0..<length {
            let byte = storage[index]
            switch byte {
            case Self.semicolon:
                keep(byte)
                // Everything after the semicolon that would start a 33rd parameter is ignored.
                if parameters == Self.limit { break scan }
                parameters += 1
                (digits, keptZero, keepsDigits, markedPastLimit) = (0, false, true, false)
            case Self.colon:
                subparameters += 1
                (digits, keptZero, keepsDigits) = (0, false, subparameters <= Self.limit)
                if keepsDigits || !markedPastLimit { keep(byte) }
                markedPastLimit = markedPastLimit || !keepsDigits
            default:
                guard keepsDigits else { continue }
                if digits == 0, byte == UInt8(ascii: "0") {
                    // An omitted subparameter differs from zero, so one zero stays.
                    if !keptZero { keep(byte) }
                    keptZero = true
                } else if digits < 11 {
                    keep(byte)
                    digits += 1
                }
            }
        }
        length = kept
    }
}
