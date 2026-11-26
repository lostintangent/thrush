/// Returns how many grid columns a scalar occupies according to the server’s Unicode 11 provider.
enum ColumnWidth {
    @inline(__always)
    static func of(_ scalar: Unicode.Scalar) -> Int { of(scalar.value) }

    /// The width of a valid scalar value.
    @inline(__always)
    static func of(_ value: UInt32) -> Int {
        let code = Int(value)
        let page = Int(pageIndices[code >> 8])
        // Each page holds eight words, each containing 32 two-bit widths.
        let word = widthWords[page * 8 + (code & 255) / 32]
        return Int((word >> ((code & 31) * 2)) & 3)
    }
}
