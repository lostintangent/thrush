#if os(macOS)
import AppKit
import ThrushCore

/// Visible terminal cells, including wide continuations, mapped to AppKit's UTF-16 text ranges.
struct MacAccessibleText {
    struct Line {
        let range: NSRange
        let cells: [NSRange]
    }
    /// A local reading position follows its row through scrollback. Keep enough of the
    /// text to detect a rewritten row without discarding the caret when its suffix grows.
    struct Caret {
        let utf16Offset: Int
        private let absoluteRow: Int
        private let isAlternate: Bool
        private let prefix: String

        init(index: Int, text: MacAccessibleText, snapshot: Terminal.Snapshot, historyOffset: Int) {
            let row = text.line(for: index)
            absoluteRow = Self.firstRow(snapshot, historyOffset) + row
            isAlternate = snapshot.isAlternate
            let offset = index - text.lines[row].range.location
            let value = snapshot.rows[row].text as NSString
            if offset < value.length {
                // NSTextView places an insertion point inside a composed character at its start.
                let character = value.rangeOfComposedCharacterSequence(at: offset)
                utf16Offset = character.location
                prefix = value.substring(to: NSMaxRange(character))
            } else {
                utf16Offset = offset
                prefix = value as String
            }
        }

        func visibleRow(in snapshot: Terminal.Snapshot?, historyOffset: Int) -> Int? {
            guard let snapshot, snapshot.isAlternate == isAlternate else { return nil }
            let row = absoluteRow - Self.firstRow(snapshot, historyOffset)
            guard snapshot.rows.indices.contains(row),
                  snapshot.rows[row].text.utf16.starts(with: prefix.utf16) else { return nil }
            return row
        }

        private static func firstRow(_ snapshot: Terminal.Snapshot, _ historyOffset: Int) -> Int {
            snapshot.history.evictedRows + snapshot.history.count - historyOffset
        }
    }

    let string: NSString
    let lines: [Line]

    init(snapshot: Terminal.Snapshot?, textIn selectionText: (TerminalView.Selection) -> String) {
        guard let snapshot else { string = ""; lines = []; return }
        var output = ""
        var offset = 0
        var lines: [Line] = []
        for (rowIndex, row) in snapshot.rows.enumerated() {
            let start = offset
            let length = selectionText(.init(anchorRow: rowIndex, anchorColumn: 0, headRow: rowIndex,
                                             headColumn: snapshot.size.columns - 1)).utf16.count
            var cells: [NSRange] = []
            var column = 0
            while offset - start < length, column < snapshot.size.columns {
                let cell = row[column]
                let value = cell.text.isEmpty ? " " : cell.text
                let count = value.utf16.count
                let span = min(max(1, cell.width), snapshot.size.columns - column)
                cells.append(contentsOf: repeatElement(NSRange(location: offset, length: count), count: span))
                output.append(value)
                offset += count
                column += span
            }
            let rowEnd = offset
            if rowIndex + 1 < snapshot.rows.count, !snapshot.rows[rowIndex + 1].isWrapped {
                output.append("\n")
                offset += 1
            }
            if cells.count < snapshot.size.columns {
                cells.append(contentsOf: repeatElement(NSRange(location: rowEnd, length: 0),
                                                       count: snapshot.size.columns - cells.count))
            }
            lines.append(Line(range: NSRange(location: start, length: offset - start), cells: cells))
        }
        self.string = output as NSString
        self.lines = lines
    }

    func line(for index: Int) -> Int {
        lines.firstIndex { index < NSMaxRange($0.range) } ?? max(0, lines.count - 1)
    }

    func range(row: Int, column: Int) -> NSRange {
        guard lines.indices.contains(row), !lines[row].cells.isEmpty else {
            return NSRange(location: row < 0 ? 0 : string.length, length: 0)
        }
        let cells = lines[row].cells
        return cells[min(cells.count - 1, max(0, column))]
    }

    func position(at index: Int, trailing: Bool = false) -> (row: Int, column: Int) {
        let row = line(for: index)
        guard lines.indices.contains(row) else { return (0, 0) }
        let cells = lines[row].cells
        if let first = cells.firstIndex(where: { NSLocationInRange(index, $0) }) {
            let last = trailing ? cells.lastIndex(of: cells[first]) ?? first : first
            return (row, last)
        }
        let column = cells.firstIndex { $0.length == 0 && index <= $0.location }
        return (row, column ?? max(0, cells.count - 1))
    }

    func range(for selection: TerminalView.Selection) -> NSRange {
        let anchor = range(row: selection.anchorRow, column: selection.anchorColumn)
        let head = range(row: selection.headRow, column: selection.headColumn)
        return NSUnionRange(anchor, head)
    }

    func selection(for range: NSRange) -> TerminalView.Selection? {
        guard range.length > 0 else { return nil }
        let first = position(at: range.location)
        let last = position(at: NSMaxRange(range) - 1)
        return .init(anchorRow: first.row, anchorColumn: first.column, headRow: last.row, headColumn: last.column)
    }
}
#endif
