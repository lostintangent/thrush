import ThrushCore

/// A logical line is a row and the soft-wrapped rows that continue it. Row indexes here count from the
/// oldest row in history.
extension Terminal.Snapshot {
    /// The rows of the logical line that holds row `index`.
    func logicalRows(containing index: Int) -> ClosedRange<Int> {
        var first = index, last = index
        while first > 0 && row(atAbsoluteIndex: first).isWrapped { first -= 1 }
        while last + 1 < history.count + rows.count && row(atAbsoluteIndex: last + 1).isWrapped { last += 1 }
        return first...last
    }

    /// The columns row `index` gives its logical line. A row that wraps on runs to the edge, unless a wide
    /// character that couldn't fit in the last column left that cell unused.
    func textEnd(in index: Int) -> Int {
        let line = row(atAbsoluteIndex: index)
        guard index + 1 < history.count + rows.count, row(atAbsoluteIndex: index + 1).isWrapped else { return line.trimmedLength }
        if line.trimmedLength < size.columns && row(atAbsoluteIndex: index + 1)[0].width == 2 { return size.columns - 1 }
        return size.columns
    }

    /// The text of the logical line in `rows`. Cells a row leaves unwritten before it wraps read as spaces.
    func text(of rows: ClosedRange<Int>) -> String {
        var text = ""
        for index in rows {
            let line = row(atAbsoluteIndex: index)
            text += line.text
            text += String(repeating: " ", count: max(0, textEnd(in: index) - line.trimmedLength))
        }
        return text
    }
}
