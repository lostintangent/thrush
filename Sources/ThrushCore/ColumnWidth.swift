/// Returns how many grid columns a scalar occupies. Using the server’s Unicode 11 widths
/// keeps wide characters and combining marks at the same cursor positions on every host.
enum ColumnWidth {
    static func of(_ scalar: Unicode.Scalar) -> Int {
        let code = scalar.value
        if code < 0x7f && code >= 0x20 { return 1 }
        if contains(code, in: zero) { return 0 }
        return contains(code, in: double) ? 2 : 1
    }

    private static func contains(_ code: UInt32, in ranges: [ClosedRange<UInt32>]) -> Bool {
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if code < range.lowerBound {
                upper = middle
            } else if code > range.upperBound {
                lower = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}
