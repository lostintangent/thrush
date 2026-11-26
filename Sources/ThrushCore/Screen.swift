// The screen every control function is written in: text prints, the cursor moves, rows scroll,
// cells shift and cells or rows are erased. A circular row index lets the normal screen scroll a
// line into history without shifting every remaining visible row.

extension Terminal {
    /// The oldest row is always at index zero, including after the backing array wraps.
    package struct History: RandomAccessCollection, Sendable {
        private var storage: [Row] = []
        private var head = 0
        package private(set) var evictedRows = 0
        // Absolute index just past the last row that came from an earlier shell. Scrolling
        // or ED 3 evicts those rows through the same ring as the current shell's rows.
        private var previousShellEnd = 0
        static let limit = 1_000
        let capacity: Int

        init(capacity: Int = Self.limit) { self.capacity = capacity }

        init(_ rows: some Collection<Row>, evictedRows: Int = 0) {
            self.init()
            storage = Array(rows)
            self.evictedRows = evictedRows
        }

        var previousShellCount: Int { Swift.max(0, previousShellEnd - evictedRows) }

        var currentShellCount: Int { count - previousShellCount }

        func retainingPreviousShells() -> Self {
            if previousShellCount == count { return self }
            return Self(prefix(previousShellCount), evictedRows: evictedRows)
        }

        mutating func markPreviousShells() { previousShellEnd = evictedRows + count }

        package var startIndex: Int { 0 }
        package var endIndex: Int { storage.count }
        package subscript(index: Int) -> Row {
            precondition(indices.contains(index))
            return storage[(head + index) % storage.count]
        }

        /// Cleared rows count as evicted, so absolute positions stay comparable across snapshots.
        mutating func removeAll() {
            evictedRows += storage.count
            storage.removeAll(keepingCapacity: true)
            head = 0
        }

        /// Moves `row` into history and leaves in its place a row the caller can clear and reuse.
        /// Once history is full, that's the oldest row, which this append evicts.
        mutating func append(_ row: inout Row) {
            guard storage.count == capacity, capacity > 0 else { return grow(with: &row) }
            evictedRows += 1
            swap(&row, &storage[head])
            head += 1
            if head == capacity { head = 0 }
        }

        /// Until history is full, it keeps each row and the caller gets a new one. Out of line, so the
        /// full ring's swap stays small enough to inline into every scroll.
        @inline(never)
        private mutating func grow(with row: inout Row) {
            guard capacity > 0 else { return }
            storage.append(row)
            row = Row(columns: row.columns, generation: row.generation)
        }
    }

    package struct Snapshot: Sendable {
        package let size: Size
        /// The palette of the app's theme. Draw through ``programColors`` to show what the program set.
        package let palette: Palette
        /// The colors the program set over the app's theme.
        package let programColors: ProgramColors
        package let modes: Modes
        package private(set) var rows: [Row]
        package let history: History
        package let normalHistoryCount: Int
        /// Rows that a taller viewport can pull from this shell's active history.
        package var currentShellHistoryCount: Int { history.currentShellCount }
        package private(set) var cursorRow: Int
        package let cursorColumn: Int
        package private(set) var cursorVisible: Bool
        package let cursorBlink: Bool
        package let cursorShape: CursorShape
        package let isAlternate: Bool
        package let generation: UInt64
        // Number `n` is `links[n - 1]`.
        let links: [Link?]
        /// A presenter can coalesce these snapshots and release the most recent one on reset or timeout.
        package var synchronizedOutputID: UInt64? { modes.synchronizedOutputID }

        /// Zero is the oldest retained row. The first live row follows the active history.
        package func row(atAbsoluteIndex index: Int) -> Row {
            index < history.count ? history[index] : rows[index - history.count]
        }
        package var mouseTracking: MouseTracking { modes.mouseTracking }

        /// The link a cell's text belongs to.
        package func link(for style: Style) -> Link? {
            style.link == 0 || style.link > links.count ? nil : links[Int(style.link) - 1]
        }

        /// Show retained rows in the same immutable generation; the live case shares its row array.
        package func viewport(rowsFromBottom offset: Int) -> Self {
            guard !isAlternate, offset > 0 else { return self }
            let count = min(history.count, offset)
            guard count > 0 else { return self }
            var result = self
            let first = history.count - count
            result.rows = (first..<(first + rows.count)).map { index in
                row(atAbsoluteIndex: index)
            }
            result.cursorRow += count
            result.cursorVisible = cursorVisible && result.cursorRow < rows.count
            return result
        }

        /// Adds `count` rows above and below a viewport, as a taller grid can bring them into view,
        /// so a view can draw them before the program answers the resize. Blank rows stand in for
        /// rows the transcript doesn't have yet. The size stays the program's.
        package func viewport(rowsFromBottom offset: Int, extendedBy count: Int) -> Self {
            let first = history.count - min(max(0, offset), history.count) - count
            let lines = 0..<(history.count + rows.count)
            var result = self
            result.rows = (first..<(first + rows.count + 2 * count)).map { index in
                lines.contains(index) ? row(atAbsoluteIndex: index) : Row(columns: size.columns, generation: 0)
            }
            result.cursorRow += history.count - first
            result.cursorVisible = cursorVisible && result.cursorRow < result.rows.count
            return result
        }
    }

    /// What DECSC and its equivalents save, and DECRC restores. Each buffer keeps its own.
    struct SavedCursor: Sendable {
        var row = 0  // Absolute within this shell, including its own history.
        var column = 0
        var style = Style()
        var characterSet = CharacterSet.ascii
    }

    /// The columns where HT stops. Each buffer starts with a stop every eight columns.
    struct TabStops: Sendable {
        private static let interval = 8
        // Stops past the right margin survive a narrower screen, as they do in the reference.
        private var stops: [Bool] = []

        init(columns: Int) {
            stops = Array(repeating: false, count: columns)
            for column in stride(from: 0, to: columns, by: Self.interval) { stops[column] = true }
        }

        subscript(column: Int) -> Bool { column >= 0 && column < stops.count && stops[column] }

        mutating func set(_ column: Int, _ isStop: Bool = true) {
            if column >= stops.count {
                guard isStop else { return }
                stops.append(contentsOf: repeatElement(false, count: column + 1 - stops.count))
            }
            stops[column] = isStop
        }

        mutating func removeAll() { stops = [] }

        /// A resize continues the default interval from the last stop left of the new margin.
        mutating func resize(to columns: Int) {
            extend(from: self[columns] ? columns : previous(before: columns, columns: columns), to: columns)
        }

        private mutating func extend(from start: Int, to columns: Int) {
            for column in stride(from: start, to: columns, by: Self.interval) { set(column) }
        }

        /// Without a later stop, the cursor stops at the right margin.
        func next(after column: Int, columns: Int) -> Int {
            let start = column + 1, end = min(columns, stops.count)
            guard start < end, let stop = stops[start..<end].firstIndex(of: true) else { return columns - 1 }
            return stop
        }

        /// Without an earlier stop, the cursor stops at the left margin.
        func previous(before column: Int, columns: Int) -> Int {
            let end = min(column, stops.count)
            guard end > 1, let stop = stops[1..<end].lastIndex(of: true) else { return 0 }
            return min(stop, columns - 1)
        }
    }

    /// A rotating viewport makes the usual full-height scroll O(1), independent of scrollback.
    struct Buffer: Sendable {
        var size: Size
        var rows: [Row]
        var head = 0
        var history = History()
        var row = 0
        var column = 0
        var saved = SavedCursor()
        var tabs: TabStops
        var scrollRegion: ClosedRange<Int>
        let alternate: Bool

        init(size: Size, alternate: Bool = false, generation: UInt64 = 0, style: Style = .init(),
             historyCapacity: Int = History.limit) {
            self.size = size
            self.alternate = alternate
            history = History(capacity: historyCapacity)
            rows = Array(repeating: Row(columns: size.columns, generation: generation, style: style), count: size.rows)
            tabs = TabStops(columns: size.columns)
            scrollRegion = 0...(size.rows - 1)
        }

        func index(of row: Int) -> Int {
            let offset = head + row
            return offset >= rows.count ? offset - rows.count : offset
        }

        var visible: [Row] {
            head == 0 ? rows : Array(rows[head...] + rows[..<head])
        }

        /// Moves the rows in `region` up and clears the rows that arrive at its bottom. With `intoHistory`,
        /// the rows leaving the top of the screen go to history. `wrapped` marks the arriving rows as
        /// continuing the line above them, as a wrap does.
        ///
        /// Rows are recycled rather than allocated. The whole screen turns by moving the ring's head, so its
        /// top row becomes its bottom row, and a smaller region rotates its rows within the ring.
        mutating func scroll(_ region: ClosedRange<Int>, up count: Int, style: Style, intoHistory: Bool,
                             wrapped: Bool, generation: UInt64) {
            let count = min(count, region.count)
            if region.count == size.rows {
                for _ in 0..<count {
                    if intoHistory { history.append(&rows[head]) }
                    rows[head].clear(columns: size.columns, generation: generation, style: style, wrapped: wrapped)
                    head = index(of: 1)
                }
                return
            }
            if intoHistory, region.lowerBound == 0 {
                for row in 0..<count { history.append(&rows[index(of: row)]) }
            }
            rotate(region, by: -count)
            let end = region.upperBound + 1
            for row in (end - count)..<end {
                rows[index(of: row)].clear(columns: size.columns, generation: generation, style: style, wrapped: wrapped)
            }
        }

        /// Moves the rows in `region` down and clears the rows that arrive at its top.
        mutating func scroll(_ region: ClosedRange<Int>, down count: Int, style: Style, generation: UInt64) {
            let count = min(count, region.count)
            if region.count == size.rows {
                for _ in 0..<count {
                    head = index(of: size.rows - 1)
                    rows[head].clear(columns: size.columns, generation: generation, style: style)
                }
                return
            }
            rotate(region, by: count)
            for row in region.lowerBound..<(region.lowerBound + count) {
                rows[index(of: row)].clear(columns: size.columns, generation: generation, style: style)
            }
        }

        /// Moves the rows in `region` down by `offset`, or up when it's negative, and wraps the rows pushed
        /// past one margin around to the other, where scrolling clears them.
        private mutating func rotate(_ region: ClosedRange<Int>, by offset: Int) {
            if head + region.lowerBound < rows.count, head + region.upperBound >= rows.count {
                // The region crosses the end of the ring, so put the rows back in screen order first.
                rows.rotate(rows.indices, by: -head)
                head = 0
            }
            let first = index(of: region.lowerBound)
            rows.rotate(first..<(first + region.count), by: offset)
        }

        /// Sets whether a row continues the line above it, and marks the row changed only when it does.
        mutating func setWrapped(_ wrapped: Bool, at row: Int, generation: UInt64) {
            let index = index(of: row)
            guard rows[index].isWrapped != wrapped else { return }
            rows[index].isWrapped = wrapped
            rows[index].generation = generation
        }
    }

    /// The grid every control function is written in. Text prints, the cursor moves, rows scroll, cells
    /// shift within rows and cells or rows are erased. Everything else is state the functions set and read.
    package struct Screen: Sendable {
        private(set) var active: Buffer
        private(set) var normalWhileAlternate: Buffer?
        // The reference keeps one alternate buffer, so its saved cursor outlasts each visit.
        private(set) var alternateSaved = SavedCursor()
        // Both buffers and every shell in history share one table, so a style's link means the same
        // wherever its row goes.
        private(set) var links = Links()
        // The reference retains its empty alternate buffer’s row capacity across an inactive shrink.
        private var alternateCapacity: Int
        private var revision: UInt64 = 0

        // Inlined because an out-of-line call copies the whole Screen first.
        @inline(__always) var row: Int { active.row }
        @inline(__always) var column: Int { active.column }
        var size: Size { active.size }
        var isAlternate: Bool { active.alternate }

        /// The rows LF, IND and RI scroll at its margins, and that IL, DL, SU, SD and the column edits act on.
        @inline(__always) var scrollRegion: ClosedRange<Int> {
            get { active.scrollRegion }
            set { active.scrollRegion = newValue }
        }

        var tabs: TabStops {
            get { active.tabs }
            set { active.tabs = newValue }
        }

        /// What DECSC saved, with its row on the screen. The buffer keeps the row within the shell's lines,
        /// so a restore follows the text as it scrolls. Without a save, it's the top left in the default style.
        var saved: SavedCursor {
            get {
                var saved = active.saved
                saved.row -= active.history.currentShellCount
                return saved
            }
            set {
                active.saved = newValue
                active.saved.row += active.history.currentShellCount
            }
        }

        init(size: Size, generation: UInt64 = 0) {
            revision = generation
            active = Buffer(size: size, generation: generation)
            alternateCapacity = size.rows
        }

        func startingShell(at size: Size, includingCurrentShell: Bool) -> Self {
            let normal = normalWhileAlternate ?? active
            var earlier = normal.history
            if includingCurrentShell {
                // Keep blank lines within the transcript and omit unused space below it.
                let rows = normal.visible
                if let last = rows.lastIndex(where: { $0.hasContent || $0.isWrapped }) {
                    for var row in rows[...last] { earlier.append(&row) }
                }
            } else {
                earlier = earlier.retainingPreviousShells()
            }
            var next = Self(size: size, generation: revision &+ 1)
            next.links = links
            next.active.prependPreviousShells(earlier, fromColumns: normal.size.columns, revision: &next.revision)
            return next
        }

        func snapshot(generation: UInt64, modes: Modes, palette: Palette, programColors: ProgramColors) -> Snapshot {
            Snapshot(size: size, palette: palette, programColors: programColors, modes: modes,
                     rows: active.visible, history: active.history,
                     normalHistoryCount: normalWhileAlternate?.history.count ?? active.history.count,
                     cursorRow: row, cursorColumn: column, cursorVisible: modes.cursorVisible,
                     cursorBlink: modes.cursorBlinkOverride ?? modes.cursorBlink, cursorShape: modes.cursorShape,
                     isAlternate: isAlternate, generation: generation, links: links.entries)
        }

        /// Returns the number that styles store for `link`, or zero when the table has no room for it.
        /// From time to time the table first frees the numbers that no row or `pen` holds.
        mutating func number(for link: Link, pen: Style) -> UInt32 {
            if links.needsSweep(before: link) { links.sweep(keeping: linksInUse(pen: pen)) }
            return links.number(for: link)
        }

        private func linksInUse(pen: Style) -> Links.NumberSet {
            var used = Links.NumberSet(through: links.entries.count)
            used.insert(pen.link)
            for buffer in [active, normalWhileAlternate] {
                guard let buffer else { continue }
                for row in buffer.history { row.insertLinks(into: &used) }
                for row in buffer.rows { row.insertLinks(into: &used) }
            }
            return used
        }

        /// A row on the screen, for the functions that read its cells or whether it continues a line.
        subscript(row row: Int) -> Row {
            precondition((0..<size.rows).contains(row))
            return active.rows[active.index(of: row)]
        }

        mutating func setAlternate(_ enabled: Bool, style: Style = .init()) {
            guard enabled != isAlternate else { return }
            let row = active.row
            let column = active.column
            if enabled {
                normalWhileAlternate = active
                revision &+= 1
                active = Buffer(size: size, alternate: true, generation: revision, style: style.eraseStyle,
                                historyCapacity: max(0, alternateCapacity - size.rows))
                active.saved = alternateSaved
            } else if let normalWhileAlternate {
                alternateCapacity = size.rows
                alternateSaved = active.saved
                active = normalWhileAlternate
                self.normalWhileAlternate = nil
            }
            active.row = row
            active.column = column
        }

        /// RIS starts over on a blank normal screen without history. The fresh rows' generation is newer
        /// than any drawn before.
        mutating func reset() {
            revision &+= 1
            active = Buffer(size: size, generation: revision)
            normalWhileAlternate = nil
            alternateSaved = SavedCursor()
            alternateCapacity = size.rows
            links = Links()
        }

        // MARK: Print

        /// Prints a run of ASCII with autowrap on and insert mode off.
        mutating func print(_ ascii: Span<UInt8>, style: Style) {
            var offset = 0
            while offset < ascii.count {
                revision &+= 1
                if column >= size.columns { wrap(style: style) }
                let count = min(ascii.count - offset, size.columns - column)
                let segment = ascii.extracting(offset..<(offset + count))
                let index = active.index(of: row)
                active.rows[index].writeASCII(segment, at: column, style: style)
                active.rows[index].generation = revision
                active.column += count
                offset += count
            }
        }

        /// Prints glyphs that carry their widths, with autowrap on and insert mode off. Returns how many it printed.
        mutating func print(_ glyphs: Span<UInt32>, style: Style, joinsPrevious: inout Bool) -> UInt64 {
            var next = 0
            while next < glyphs.count {
                let index = active.index(of: row)
                let limit = min(size.columns, active.rows[index].storageColumns)
                let glyph = StoredCell(glyph: glyphs[next])
                let width = glyph.width
                if width > 0, column + width <= limit, column >= active.rows[index].length {
                    let n = active.rows[index].appendRun(glyphs, from: &next, at: column, limit: limit, style: style)
                    active.column = active.rows[index].length
                    revision &+= n
                    active.rows[index].generation = revision
                    joinsPrevious = true
                } else {
                    print(Unicode.Scalar(glyph.scalar)!, width: width, style: style, wraparound: true, insert: false,
                          joinsPrevious: joinsPrevious)
                    joinsPrevious = width > 0 || joinsPrevious
                    next += 1
                }
            }
            return UInt64(glyphs.count)
        }

        /// Prints one scalar. A zero-width one joins the character before the cursor when `joinsPrevious`.
        mutating func print(_ scalar: Unicode.Scalar, width: Int, style: Style, wraparound: Bool, insert: Bool,
                            joinsPrevious: Bool = true) {
            revision &+= 1
            if width == 0, joinsPrevious, column > 0 {
                let index = active.index(of: row)
                active.rows[index].appendCombining(scalar, before: column)
                active.rows[index].generation = revision
                return
            }
            if column + width > size.columns {
                if wraparound {
                    if column < size.columns {
                        let index = active.index(of: row)
                        active.rows[index].erase(column..<size.columns, style: style)
                        active.rows[index].generation = revision
                        revision &+= 1
                    }
                    wrap(style: style)
                } else {
                    // Without autowrap, each character replaces the last column. A wide one doesn't fit there.
                    active.column = size.columns - 1
                    if width == 2 { return }
                }
            }
            let index = active.index(of: row)
            if column < active.rows[index].storageColumns {
                if insert { active.rows[index].editCharacters(.insert, at: column, count: width, style: style) }
                active.rows[index].write(scalar, at: column, width: width, style: style)
                active.rows[index].generation = revision
            }
            // A standalone combining mark occupies a cell of width zero. At the pending wrap
            // margin the cursor advances even though no visible cell receives the mark.
            active.column += max(1, width)
        }

        /// Text that reaches the right margin continues at the start of the next row, which continues this
        /// row's line. At the bottom margin the region scrolls up, and below the region the last row stays.
        private mutating func wrap(style: Style) {
            active.column = 0
            if row == scrollRegion.upperBound {
                active.scroll(scrollRegion, up: 1, style: style.eraseStyle, intoHistory: true, wrapped: true,
                              generation: revision)
            } else {
                active.row = min(row + 1, size.rows - 1)
                active.setWrapped(true, at: row, generation: revision)
            }
        }

        // MARK: Move

        /// Puts the cursor on a cell, clamped to the screen. Clamping the column to the last one ends a pending wrap.
        mutating func move(toRow row: Int, column: Int) {
            active.row = min(max(0, row), size.rows - 1)
            active.column = min(max(0, column), size.columns - 1)
        }

        /// Moves the cursor to a row, clamped to the screen, and keeps its column, so a pending wrap survives.
        mutating func move(toRow row: Int) {
            active.row = min(max(0, row), size.rows - 1)
        }

        /// Moves the cursor along its row. Past the last column it stops at the pending wrap.
        mutating func move(toColumn column: Int) {
            active.column = min(max(0, column), size.columns)
        }

        // MARK: Scroll

        /// Moves the rows of a range up by `count` and blanks the rows that arrive at its bottom in `style`.
        /// With `intoHistory`, the rows leaving the top of the screen go to history instead of away.
        mutating func scroll(_ rows: ClosedRange<Int>, up count: Int, style: Style, intoHistory: Bool = false) {
            revision &+= 1
            active.scroll(rows, up: count, style: style, intoHistory: intoHistory, wrapped: false, generation: revision)
        }

        /// Moves the rows of a range down by `count` and blanks the rows that arrive at its top in `style`.
        mutating func scroll(_ rows: ClosedRange<Int>, down count: Int, style: Style) {
            revision &+= 1
            active.scroll(rows, down: count, style: style, generation: revision)
        }

        // MARK: Shift

        /// Slides the cells of each row from `column` right by `count` and blanks the cells that open in
        /// `style`. Cells pushed past the end go, including an alternate row's hidden columns.
        mutating func shift(_ rows: ClosedRange<Int>, at column: Int, right count: Int, style: Style) {
            shift(.insert, rows, at: column, count: count, style: style)
        }

        /// Slides the cells of each row after `column + count` left to `column` and blanks the cells that
        /// arrive at the end in `style`.
        mutating func shift(_ rows: ClosedRange<Int>, at column: Int, left count: Int, style: Style) {
            shift(.delete, rows, at: column, count: count, style: style)
        }

        /// As in the reference, a column past a row's stored cells wraps to its first. Each row gets its own
        /// generation, because the rows hold different cells.
        private mutating func shift(_ edit: CharacterEdit, _ rows: ClosedRange<Int>, at column: Int, count: Int,
                                    style: Style) {
            for row in rows {
                revision &+= 1
                let index = active.index(of: row)
                let start = column % active.rows[index].storageColumns
                active.rows[index].editCharacters(edit, at: start, count: count, style: style)
                active.rows[index].generation = revision
            }
        }

        // MARK: Erase

        /// Blanks cells in a row in `style`, clipped to the cells the row stores. A narrowed alternate row
        /// stores its hidden columns too.
        mutating func erase(_ columns: Range<Int>, inRow row: Int, style: Style) {
            revision &+= 1
            let index = active.index(of: row)
            active.rows[index].erase(columns.clamped(to: 0..<active.rows[index].storageColumns), style: style)
            active.rows[index].generation = revision
        }

        /// Replaces whole rows, hidden alternate columns included, with blanks in `style`, each starting a
        /// new line. With `filling`, every cell holds that ASCII character in `style` instead.
        mutating func erase(rows: Range<Int>, style: Style, filling: Unicode.Scalar? = nil) {
            revision &+= 1
            for row in rows {
                let index = active.index(of: row)
                let columns = active.rows[index].storageColumns
                active.rows[index].clear(columns: columns, generation: revision, style: filling == nil ? style : Style())
                active.rows[index].columns = size.columns
                if let filling {
                    let pattern = [UInt8](repeating: UInt8(ascii: filling), count: columns)
                    active.rows[index].writeASCII(pattern.span, at: 0, style: style)
                }
            }
        }

        /// Empties history and leaves the screen and saved cursor as they are.
        mutating func eraseHistory() { active.history.removeAll() }

        // MARK: State

        /// Makes a row start a new line rather than continue the one above it.
        mutating func startLine(at row: Int) {
            revision &+= 1
            active.setWrapped(false, at: row, generation: revision)
        }

        mutating func resize(to size: Size) {
            guard size != active.size else { return }
            alternateCapacity = isAlternate ? size.rows : max(alternateCapacity, size.rows)
            active.resize(to: size, revision: &revision)
            normalWhileAlternate?.resize(to: size, revision: &revision)
        }
    }
}
