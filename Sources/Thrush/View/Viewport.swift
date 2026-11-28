import ThrushCore

/// Cell indexes in this type include retained history. Only the native view deals in viewport coordinates.
struct Viewport {
    typealias Selection = TerminalMetalView.Selection

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
        source = next
        if old.size != next.size {
            guard offset > 0 || absoluteSelection != nil else { return }
            let before = Lines(old), after = Lines(next, numberedLike: before)
            func find(_ position: Position) -> Position? { after.position(of: position, from: before, nearest: true) }
            if offset > 0 { scroll(next.history.count - (find(.init(row: oldTop, column: 0))?.row ?? 0)) }
            if let range = absoluteSelection {
                absoluteSelection = find(range.anchor).flatMap { a in find(range.head).map { .init(anchor: a, head: $0) } }
            }
            return
        }
        let discarded = max(0, next.history.evictedRows - old.history.evictedRows)
        if offset > 0 { scroll(next.history.count - max(0, oldTop - discarded)) }
        if let range = absoluteSelection, discarded > 0 {
            let shifted = range.shifted(by: -discarded)
            absoluteSelection = min(shifted.headRow, shifted.anchorRow) >= 0 ? shifted : nil
        }
    }

    mutating func replace(_ next: Terminal.Snapshot, archivingMainScreen: Bool = false) {
        if archivingMainScreen {
            // Main-screen rows keep their positions in scrollback, including identical prompts.
            display(next)
            if let range = absoluteSelection, max(range.anchorRow, range.headRow) >= next.history.count {
                absoluteSelection = nil // The old screen's unused trailing rows were discarded.
            }
            return
        }
        // Serialized replay has its own history indexes. Identify surviving rows by their logical text.
        guard let old = source, old.isAlternate == next.isAlternate,
              offset > 0 || absoluteSelection != nil else {
            source = next
            offset = 0
            absoluteSelection = nil
            return
        }

        let before = Lines(old), after = Lines(next, numberedLike: before)
        func find(_ position: Position) -> Position? { after.position(of: position, from: before, nearest: false) }
        let oldTop = top
        let wasReading = offset > 0
        let previousRange = absoluteSelection
        let previousText = selection.map { text(in: $0) }
        source = next
        offset = 0
        absoluteSelection = nil

        if wasReading {
            let first = find(.init(row: oldTop, column: 0))?.row
                ?? after.nearestSurvivingRow(to: before.lineAtRow[oldTop], from: before) ?? 0
            scroll(next.history.count - first)
        }

        guard let previousRange, let previousText, let a = find(previousRange.anchor), let b = find(previousRange.head),
              (previousRange.anchor <= previousRange.head) == (a <= b) else { return }
        let candidate = Selection(anchor: a, head: b)
        if text(in: candidate.shifted(by: -top)).utf8.elementsEqual(previousText.utf8) {
            absoluteSelection = candidate
        }
    }

    /// A snapshot's logical lines, each known by its text and its neighbours' text. Resize and replay
    /// rebuild every row, so both find a line again by its text and as many of its neighbours as agree.
    /// Resize takes the nearest of the best-agreeing lines. Replay takes one only when the most specific
    /// agreement names it alone in both snapshots, since a repeated line can't prove which copy a person
    /// was reading.
    private final class Lines {
        struct Line {
            let rows: ClosedRange<Int>
            let text: Int
        }

        struct Context: Hashable {
            let before: Int?
            let text: Int
            let after: Int?
        }

        let source: Terminal.Snapshot
        private(set) var lines: [Line] = []
        private(set) var lineAtRow: [Int] = []
        /// A number for each distinct text, so lines compare as numbers. Lines matched against these
        /// carry on the same numbering.
        private var numbers: [String: Int]
        /// The line each context names, or -1 when it names more than one. Only replay asks.
        private lazy var occurrences: [Context: Int] = {
            var named: [Context: Int] = [:]
            named.reserveCapacity(lines.count * 4)
            for index in lines.indices {
                for context in contexts(at: index) {
                    if named.updateValue(index, forKey: context) != nil { named[context] = -1 }
                }
            }
            return named
        }()

        init(_ source: Terminal.Snapshot, numberedLike other: Lines? = nil) {
            self.source = source
            numbers = other?.numbers ?? [:]
            numbers.reserveCapacity(numbers.count + source.count)
            lineAtRow.reserveCapacity(source.count)
            var start = 0
            while start < source.count {
                let rows = source.logicalRows(containing: start)
                let line = source.text(of: rows)
                let text = numbers[line] ?? numbers.count
                numbers[line] = text
                lineAtRow.append(contentsOf: repeatElement(lines.count, count: rows.count))
                lines.append(Line(rows: rows, text: text))
                start = rows.upperBound + 1
            }
        }

        private func contexts(at index: Int) -> [Context] {
            let text = lines[index].text
            let before = index > 0 ? lines[index - 1].text : nil
            let after = index + 1 < lines.count ? lines[index + 1].text : nil
            var result = [Context(before: nil, text: text, after: nil)]
            if let before { result.append(Context(before: before, text: text, after: nil)) }
            if let after { result.append(Context(before: nil, text: text, after: after)) }
            if let before, let after { result.append(Context(before: before, text: text, after: after)) }
            return result
        }

        /// The line here that is line `index` of `old`.
        func match(_ index: Int, from old: Lines, nearest: Bool) -> Int? {
            guard nearest else {
                var best = -1, matched: Int?
                for context in old.contexts(at: index) where old.occurrences[context] == index {
                    guard let target = occurrences[context], target >= 0 else { continue }
                    let score = (context.before == nil ? 0 : 1) + (context.after == nil ? 0 : 1)
                    if score > best { (best, matched) = (score, target) } else if score == best && matched != target { matched = nil }
                }
                return matched
            }
            func agree(_ line: Int, _ oldLine: Int) -> Int {
                lines.indices.contains(line) && old.lines.indices.contains(oldLine) && lines[line].text == old.lines[oldLine].text ? 1 : 0
            }
            let start = old.lines[index].rows.lowerBound
            var best: (line: Int, score: Int, distance: Int)?
            for (line, candidate) in lines.enumerated() where candidate.text == old.lines[index].text {
                let score = agree(line - 1, index - 1) + agree(line + 1, index + 1)
                let distance = abs(candidate.rows.lowerBound - start)
                if best.map({ (score, -distance) > ($0.score, -$0.distance) }) ?? true { best = (line, score, distance) }
            }
            return best?.line
        }

        /// Where `position` in `old` is here: as far along its matched line, or at that line's last cell
        /// if the line no longer reaches so far.
        func position(of position: Position, from old: Lines, nearest: Bool) -> Position? {
            let row = min(max(0, position.row), old.lineAtRow.count - 1)
            let line = old.lineAtRow[row]
            guard let target = match(line, from: old, nearest: nearest) else { return nil }
            let offset = old.source.cellOffset(of: .init(row: row, column: max(0, position.column)), in: old.lines[line].rows)
            let rows = lines[target].rows
            return source.position(at: offset, in: rows) ?? .init(row: rows.upperBound, column: source.size.columns - 1)
        }

        func nearestSurvivingRow(to index: Int, from old: Lines) -> Int? {
            for distance in 1..<old.lines.count {
                let following = index + distance
                if following < old.lines.count, let target = match(following, from: old, nearest: false) {
                    return lines[target].rows.lowerBound
                }
                let preceding = index - distance
                if preceding >= 0, let target = match(preceding, from: old, nearest: false) {
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
                result.append(cell.text(spoken: spoken))
                column += max(1, cell.width)
            }
        }
        return result
    }

    /// The logical line through `row`, from its first cell to the end of its text.
    func line(row: Int) -> Selection? {
        guard let source else { return nil }
        let rows = source.logicalRows(containing: min(max(top + row, 0), source.count - 1))
        return Selection(anchorRow: rows.lowerBound, anchorColumn: 0, headRow: rows.upperBound,
                         headColumn: max(0, source.textEnd(in: rows.upperBound) - 1)).shifted(by: -top)
    }

    mutating func selectLine(row: Int) {
        selection = line(row: row)
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
}

extension Terminal.Cell {
    /// The cell's copied or spoken text, where an empty cell reads as a space. Spoken concealed text reads as
    /// one space per UTF-16 unit, so spoken and copied text share every range.
    func text(spoken: Bool) -> String {
        if text.isEmpty { return " " }
        return spoken && style.invisible ? String(repeating: " ", count: text.utf16.count) : text
    }
}

private extension TerminalMetalView.Selection {
    typealias Position = Viewport.Position
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

    func cellOffset(of position: Viewport.Position, in rows: ClosedRange<Int>) -> Int {
        (rows.lowerBound..<position.row).reduce(position.column) { $0 + textEnd(in: $1) }
    }

    func position(at offset: Int, in rows: ClosedRange<Int>) -> Viewport.Position? {
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
}
