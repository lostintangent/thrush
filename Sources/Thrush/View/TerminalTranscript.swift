import ThrushCore

/// Cell indexes in this type include retained history. Only the native view deals in viewport coordinates.
struct TerminalTranscript {
    typealias Selection = TerminalView.Selection

    struct Position: Comparable {
        var row: Int
        var column: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.row, lhs.column) < (rhs.row, rhs.column)
        }
    }

    private(set) var source: Terminal.Snapshot?
    private(set) var offset = 0
    private var absoluteSelection: Selection?

    var historyCount: Int { source.map { $0.isAlternate ? 0 : $0.history.count } ?? 0 }
    private var top: Int { (source?.history.count ?? 0) - offset }
    var selection: Selection? {
        get { absoluteSelection?.shifted(by: -top) }
        set { absoluteSelection = newValue?.shifted(by: top) }
    }

    mutating func scroll(_ rowsFromBottom: Int) {
        offset = min(max(0, rowsFromBottom), historyCount)
    }

    mutating func display(_ next: Terminal.Snapshot) {
        guard let old = source else { source = next; return }
        guard old.isAlternate == next.isAlternate else {
            source = next
            offset = 0
            absoluteSelection = nil
            return
        }
        let oldTop = top
        let resized = old.size != next.size
        let discarded = max(0, next.history.evictedRows - old.history.evictedRows)
        source = next
        if offset > 0 {
            let anchored: Int
            if resized {
                let anchor = LineAnchor(position: .init(row: oldTop, column: 0), in: old)
                anchored = anchor.resolve(in: next)?.row ?? 0
            } else {
                anchored = max(0, oldTop - discarded)
            }
            scroll(next.history.count - anchored)
        }
        guard let range = absoluteSelection else { return }
        if resized {
            guard let a = LineAnchor(position: range.anchor, in: old).resolve(in: next),
                  let b = LineAnchor(position: range.head, in: old).resolve(in: next) else {
                absoluteSelection = nil
                return
            }
            absoluteSelection = .init(anchor: a, head: b)
        } else if discarded > 0 {
            let shifted = range.shifted(by: -discarded)
            absoluteSelection = min(shifted.headRow, shifted.anchorRow) >= 0 ? shifted : nil
        }
    }

    /// Install the complete state of a serialized replay. Revisions and history indexes
    /// belong to the previous emulator, so only logical text can identify a surviving row.
    mutating func replace(_ next: Terminal.Snapshot) {
        guard let old = source, old.isAlternate == next.isAlternate,
              offset > 0 || absoluteSelection != nil else {
            source = next
            offset = 0
            absoluteSelection = nil
            return
        }

        let before = ReplayLines(old)
        let after = ReplayLines(next)
        let oldTop = top
        let wasReading = offset > 0
        let previousRange = absoluteSelection
        let previousText = selection.map { text(in: $0) }
        source = next
        offset = 0
        absoluteSelection = nil

        if wasReading {
            let line = before.lineAtRow[oldTop]
            let first: Int
            if let target = after.match(line, from: before) {
                let column = old.cellOffset(of: .init(row: oldTop, column: 0), in: before.lines[line].rows)
                first = next.position(at: column, in: after.lines[target].rows)?.row ?? after.lines[target].rows.lowerBound
            } else {
                first = after.nearestSurvivingRow(to: line, from: before) ?? 0
            }
            scroll(next.history.count - first)
        }

        guard let previousRange, let previousText else { return }
        func endpoint(_ position: Position) -> Position? {
            guard before.lineAtRow.indices.contains(position.row), (0..<old.size.columns).contains(position.column) else { return nil }
            let line = before.lineAtRow[position.row]
            guard let target = after.match(line, from: before) else { return nil }
            let column = old.cellOffset(of: position, in: before.lines[line].rows)
            return next.position(at: column, in: after.lines[target].rows)
        }
        guard let a = endpoint(previousRange.anchor), let b = endpoint(previousRange.head),
              (previousRange.anchor <= previousRange.head) == (a <= b) else { return }
        let candidate = Selection(anchor: a, head: b)
        if text(in: candidate.shifted(by: -top)).utf8.elementsEqual(previousText.utf8) {
            absoluteSelection = candidate
        }
    }

    private struct ReplayLines {
        struct Line {
            let rows: ClosedRange<Int>
            let bytes: [UInt8]
        }

        struct Context: Hashable {
            let before: [UInt8]?
            let text: [UInt8]
            let after: [UInt8]?
        }

        var lines: [Line] = []
        var lineAtRow: [Int] = []
        // A negative value means that this sequence occurs more than once.
        private var occurrences: [Context: Int] = [:]

        init(_ source: Terminal.Snapshot) {
            var start = 0
            while start < source.count {
                let rows = source.logicalRows(containing: start)
                lineAtRow.append(contentsOf: repeatElement(lines.count, count: rows.count))
                lines.append(Line(rows: rows, bytes: Array(source.lineText(rows).utf8)))
                start = rows.upperBound + 1
            }
            for index in lines.indices {
                for context in contexts(at: index) {
                    occurrences[context] = occurrences[context] == nil ? index : -1
                }
            }
        }

        private func contexts(at index: Int) -> [Context] {
            let text = lines[index].bytes
            let before = index > 0 ? lines[index - 1].bytes : nil
            let after = index + 1 < lines.count ? lines[index + 1].bytes : nil
            var result = [Context(before: nil, text: text, after: nil)]
            if let before { result.append(Context(before: before, text: text, after: nil)) }
            if let after { result.append(Context(before: nil, text: text, after: after)) }
            if let before, let after { result.append(Context(before: before, text: text, after: after)) }
            return result
        }

        /// Both snapshots must identify a single occurrence. If two equally specific
        /// neighbors point to different copies, neither one proves the old identity.
        func match(_ index: Int, from old: Self) -> Int? {
            var best = -1
            var matched: Int?
            for context in old.contexts(at: index) {
                guard old.occurrences[context] == index, let target = occurrences[context], target >= 0 else { continue }
                let score = (context.before == nil ? 0 : 1) + (context.after == nil ? 0 : 1)
                if score > best {
                    best = score
                    matched = target
                } else if score == best && matched != target {
                    matched = nil
                }
            }
            return matched
        }

        func nearestSurvivingRow(to index: Int, from old: Self) -> Int? {
            for distance in 1..<old.lines.count {
                let following = index + distance
                if following < old.lines.count, let target = match(following, from: old) {
                    return lines[target].rows.lowerBound
                }
                let preceding = index - distance
                if preceding >= 0, let target = match(preceding, from: old) {
                    return lines[target].rows.upperBound
                }
            }
            return nil
        }
    }

    /// Like a terminal emulator's line translation, keep printed spaces and omit unused trailing cells.
    /// Copied text keeps concealed characters, so selecting and copying reveals them as in other
    /// terminals. Spoken text reads them as the blank cells they show.
    func text(in selection: Selection, spoken: Bool = false) -> String {
        guard let source else { return "" }
        let range = selection.shifted(by: top)
        let a = min(range.anchor, range.head), b = max(range.anchor, range.head)
        let lo = max(0, a.row), hi = min(source.count - 1, b.row)
        guard lo <= hi else { return "" }
        var result = ""
        for y in lo...hi {
            let row = source.row(atAbsoluteIndex: y)
            if y > lo && !row.isWrapped { result.append("\n") }
            var column = y == a.row ? min(max(0, a.column), source.size.columns - 1) : 0
            if column > 0 && row[column - 1].width == 2 { column -= 1 }
            let end = y == b.row ? min(max(-1, b.column), source.size.columns - 1) : source.size.columns - 1
            let limit = min(end + 1, source.textEnd(in: y))
            while column < limit {
                let cell = row[column]
                result.append(cell.transcriptText(spoken: spoken))
                column += max(1, cell.width)
            }
        }
        return result
    }

    mutating func selectLine(row: Int) {
        guard let source else { return }
        let absolute = min(max(top + row, 0), source.count - 1)
        let lines = source.logicalRows(containing: absolute)
        absoluteSelection = .init(anchorRow: lines.lowerBound, anchorColumn: 0, headRow: lines.upperBound,
                                  headColumn: max(0, source.textEnd(in: lines.upperBound) - 1))
    }

    mutating func selectWord(row: Int, column: Int) {
        guard let source else { return }
        let y = min(max(top + row, 0), source.count - 1)
        let x = min(max(column, 0), source.size.columns - 1)
        let lines = source.logicalRows(containing: y)
        // Gather cells of just this logical line. The two halves of a wide glyph occupy one token.
        var spans: [(start: Position, end: Position, group: Int)] = []
        var selected = 0
        for index in lines {
            let row = source.row(atAbsoluteIndex: index)
            let end = max(source.textEnd(in: index), index == y ? x + 1 : 0)
            var c = 0
            while c < end {
                let cell = row[c]
                let last = c + max(1, cell.width) - 1
                if index == y, (c...last).contains(x) { selected = spans.count }
                let group = Self.wordGroup(cell.text)
                spans.append((.init(row: index, column: c), .init(row: index, column: last), group))
                c = last + 1
            }
        }
        guard !spans.isEmpty else { return }
        var first = selected, last = selected
        let group = spans[selected].group
        while first > 0 && spans[first - 1].group == group { first -= 1 }
        while last + 1 < spans.count && spans[last + 1].group == group { last += 1 }
        absoluteSelection = .init(anchor: spans[first].start, head: spans[last].end)
    }

    private static func wordGroup(_ text: String) -> Int {
        guard let c = text.first, !c.isWhitespace else { return 0 }
        return "()[]{}'\"\u{60},;:".contains(c) ? Int(c.unicodeScalars.first!.value) + 2 : 1
    }

    /// During resize every physical row is rebuilt. Re-find the logical line and the selected
    /// column in its new wraps. Matching its neighbours distinguishes repeated prompt/log lines.
    private struct LineAnchor {
        let text: String, preceding: String?, following: String?
        let oldStart: Int, cellOffset: Int

        init(position: Position, in source: Terminal.Snapshot) {
            let row = min(max(0, position.row), source.count - 1)
            let lines = source.logicalRows(containing: row)
            text = source.lineText(lines)
            oldStart = lines.lowerBound
            preceding = oldStart > 0 ? source.lineText(source.logicalRows(containing: oldStart - 1)) : nil
            following = lines.upperBound + 1 < source.count
                ? source.lineText(source.logicalRows(containing: lines.upperBound + 1)) : nil
            cellOffset = source.cellOffset(of: .init(row: row, column: max(0, position.column)), in: lines)
        }

        func resolve(in source: Terminal.Snapshot) -> Position? {
            var best: (rows: ClosedRange<Int>, neighbours: Int, distance: Int)?
            var start = 0
            while start < source.count {
                let rows = source.logicalRows(containing: start)
                if source.lineText(rows) == text {
                    var score = 0
                    if let preceding, start > 0,
                       source.lineText(source.logicalRows(containing: start - 1)) == preceding { score += 1 }
                    if let following, rows.upperBound + 1 < source.count,
                       source.lineText(source.logicalRows(containing: rows.upperBound + 1)) == following { score += 1 }
                    let distance = abs(start - oldStart)
                    if best == nil || score > best!.neighbours || (score == best!.neighbours && distance < best!.distance) {
                        best = (rows, score, distance)
                    }
                }
                start = rows.upperBound + 1
            }
            guard let rows = best?.rows else { return nil }
            return source.position(at: cellOffset, in: rows)
                ?? .init(row: rows.upperBound, column: source.size.columns - 1)
        }
    }
}

extension Terminal.Cell {
    /// Concealed text reads as one space per UTF-16 unit, so spoken and copied text share every range.
    func transcriptText(spoken: Bool) -> String {
        if text.isEmpty { return " " }
        return spoken && style.invisible ? String(repeating: " ", count: text.utf16.count) : text
    }
}

private extension TerminalView.Selection {
    typealias Position = TerminalTranscript.Position
    var anchor: Position { .init(row: anchorRow, column: anchorColumn) }
    var head: Position { .init(row: headRow, column: headColumn) }

    init(anchor: Position, head: Position) {
        self.init(anchorRow: anchor.row, anchorColumn: anchor.column, headRow: head.row, headColumn: head.column)
    }

    func shifted(by delta: Int) -> Self {
        .init(anchorRow: anchorRow + delta, anchorColumn: anchorColumn, headRow: headRow + delta, headColumn: headColumn)
    }
}

private extension Terminal.Snapshot {
    var count: Int { history.count + rows.count }

    func cellOffset(of position: TerminalTranscript.Position, in rows: ClosedRange<Int>) -> Int {
        (rows.lowerBound..<position.row).reduce(position.column) { $0 + textEnd(in: $1) }
    }

    func position(at offset: Int, in rows: ClosedRange<Int>) -> TerminalTranscript.Position? {
        var column = offset
        for row in rows {
            if row == rows.upperBound {
                return column < size.columns ? .init(row: row, column: column) : nil
            }
            let length = textEnd(in: row)
            if column < length { return .init(row: row, column: column) }
            column -= length
        }
        return nil
    }

    func logicalRows(containing row: Int) -> ClosedRange<Int> {
        var first = row, last = row
        while first > 0 && rowAt(first).isWrapped { first -= 1 }
        while last + 1 < count && rowAt(last + 1).isWrapped { last += 1 }
        return first...last
    }

    func textEnd(in row: Int) -> Int {
        let line = rowAt(row)
        guard row + 1 < count, rowAt(row + 1).isWrapped else { return line.trimmedLength }
        // A wide glyph that could not fit in the final column left an unused wrap cell behind.
        if line.trimmedLength < size.columns && rowAt(row + 1)[0].width == 2 { return size.columns - 1 }
        return size.columns
    }

    func lineText(_ rows: ClosedRange<Int>) -> String {
        var text = ""
        for y in rows {
            let row = rowAt(y)
            text.append(row.text)
            text.append(String(repeating: " ", count: max(0, textEnd(in: y) - row.trimmedLength)))
        }
        return text
    }

    func rowAt(_ index: Int) -> Terminal.Row { row(atAbsoluteIndex: index) }
}
