// Applies cursor movement, printing, erasing and scrolling to the active screen.
// A circular row index lets the normal screen scroll a line into history without shifting
// every remaining visible row.

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
            guard capacity > 0 else { return }
            if storage.count == capacity {
                evictedRows += 1
                swap(&row, &storage[head])
                head += 1
                if head == capacity { head = 0 }
            } else {
                storage.append(row)
                row = Row(columns: row.columns, generation: row.generation)
            }
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
        var scrollTop = 0
        var scrollBottom: Int
        let alternate: Bool

        init(size: Size, alternate: Bool = false, generation: UInt64 = 0, style: Style = .init(),
             historyCapacity: Int = History.limit) {
            self.size = size
            self.alternate = alternate
            history = History(capacity: historyCapacity)
            rows = Array(repeating: Row(columns: size.columns, generation: generation, style: style), count: size.rows)
            tabs = TabStops(columns: size.columns)
            scrollBottom = size.rows - 1
        }

        func index(of row: Int) -> Int {
            let offset = head + row
            return offset >= rows.count ? offset - rows.count : offset
        }

        var visible: [Row] {
            head == 0 ? rows : Array(rows[head...] + rows[..<head])
        }

        /// Moves the cursor down a row and scrolls the region when it leaves the bottom margin.
        /// A wrap marks the next row as continuing this one and a line feed starts a new line.
        /// IND passes `nil` to leave the next row's continuation as it is.
        mutating func advanceLine(wrapped: Bool?, eraseStyle: Style, generation: UInt64) {
            if row != scrollBottom {
                let next = min(row + 1, size.rows - 1)
                if let wrapped, wrapped || next != row {
                    let index = index(of: next)
                    if rows[index].isWrapped != wrapped {
                        rows[index].isWrapped = wrapped
                        rows[index].generation = generation
                    }
                }
                row = next
                return
            }

            if scrollTop == 0 {
                history.append(&rows[head])
                if scrollBottom == size.rows - 1 {
                    rows[head].clear(columns: size.columns, generation: generation, style: eraseStyle,
                                     wrapped: wrapped ?? false)
                    head += 1
                    if head == size.rows { head = 0 }
                    return
                }
            }
            deleteRows(1, at: scrollTop, through: scrollBottom, generation: generation, style: eraseStyle,
                       wrapped: wrapped ?? false)
        }

        /// Removes rows at `top` and moves the rows below them up. The removed rows rotate down to the
        /// freed rows above `bottom` and are cleared there, so scrolling a region never allocates a row.
        mutating func deleteRows(_ count: Int, at top: Int, through bottom: Int, generation: UInt64,
                                 style: Style = .init(), wrapped: Bool = false) {
            let count = min(count, bottom - top + 1)
            rotate(top...bottom, by: -count)
            for y in (bottom + 1 - count)...bottom {
                rows[index(of: y)].clear(columns: size.columns, generation: generation, style: style, wrapped: wrapped)
            }
        }

        /// Opens rows at `top` and moves the rows below them down. The rows pushed past `bottom` rotate
        /// up to the opened rows and are cleared there.
        mutating func insertRows(_ count: Int, at top: Int, through bottom: Int, generation: UInt64,
                                 style: Style = .init()) {
            let count = min(count, bottom - top + 1)
            rotate(top...bottom, by: count)
            for y in top..<(top + count) {
                rows[index(of: y)].clear(columns: size.columns, generation: generation, style: style)
            }
        }

        /// Moves the rows in `region` down by `offset`, or up when it's negative, and wraps the rows pushed
        /// past one margin around to the other.
        private mutating func rotate(_ region: ClosedRange<Int>, by offset: Int) {
            if head + region.lowerBound < rows.count, head + region.upperBound >= rows.count {
                // The region crosses the end of the ring, so put the rows back in screen order first.
                rows.rotate(rows.indices, by: -head)
                head = 0
            }
            let first = index(of: region.lowerBound)
            rows.rotate(first..<(first + region.count), by: offset)
        }
    }

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
        @inline(__always) var scrollTop: Int { active.scrollTop }
        @inline(__always) var scrollBottom: Int { active.scrollBottom }
        var isAlternate: Bool { active.alternate }

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

        func text(inRow row: Int) -> String {
            precondition((0..<size.rows).contains(row))
            return active.rows[active.index(of: row)].text
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

        /// The column may be just past the right margin, so a restore can bring back a pending wrap.
        /// A restore keeps the open link, so the saved style leaves it out.
        mutating func saveCursor(style: Style, characterSet: CharacterSet) {
            var style = style
            style.link = 0
            active.saved = SavedCursor(row: active.history.currentShellCount + row, column: column, style: style, characterSet: characterSet)
        }

        /// Without a save, the cursor returns home with the default style.
        mutating func restoreCursor() -> SavedCursor {
            let saved = active.saved
            move(toRow: saved.row - active.history.currentShellCount, column: saved.column)
            return saved
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

        /// DECSTR returns a later restore to the top of the screen with the default style and ASCII.
        mutating func resetSavedCursor() {
            active.saved = SavedCursor(row: active.history.currentShellCount)
        }

        /// Origin mode keeps the cursor within the scroll region. The column stays, so a pending wrap survives.
        mutating func moveIntoScrollRegion() {
            active.row = min(max(row, scrollTop), scrollBottom)
        }

        mutating func move(toRow row: Int, column: Int) {
            active.row = min(max(0, row), size.rows - 1)
            active.column = min(max(0, column), size.columns - 1)
        }

        // CUU/CUD stop at the scroll margin when approached from inside it.
        mutating func cursorUp(_ count: Int) {
            move(toRow: max(row >= scrollTop ? scrollTop : 0, row - count), column: column)
        }

        mutating func cursorDown(_ count: Int) {
            move(toRow: min(row <= scrollBottom ? scrollBottom : size.rows - 1, row + count), column: column)
        }

        mutating func cursorForward(_ count: Int) {
            move(toRow: row, column: column + count)
        }

        mutating func cursorBackward(_ count: Int) {
            // A pending wrap still measures CUB from the last visible column.
            move(toRow: row, column: min(column, size.columns - 1) - count)
        }

        // CNL and CPL move as CUD and CUU do, then return to the first column.
        mutating func cursorNextLine(_ count: Int) {
            cursorDown(count)
            carriageReturn()
        }

        mutating func cursorPrecedingLine(_ count: Int) {
            cursorUp(count)
            carriageReturn()
        }

        mutating func setScrollRegion(top: Int, bottom: Int) {
            if top >= 0, top < bottom, bottom < size.rows {
                active.scrollTop = top
                active.scrollBottom = bottom
            }
        }

        /// Restores the full-screen region, as DECSTR and DECALN do, and leaves the cursor where it is.
        mutating func resetScrollRegion() {
            active.scrollTop = 0
            active.scrollBottom = size.rows - 1
        }

        mutating func carriageReturn() { active.column = 0 }

        mutating func lineFeed(style: Style = .init()) {
            revision &+= 1
            if column >= size.columns { active.column -= 1 }
            active.advanceLine(wrapped: false, eraseStyle: style.eraseStyle, generation: revision)
        }

        /// IND moves down as LF does, but leaves the next row's continuation unchanged.
        mutating func index(style: Style) {
            revision &+= 1
            active.column = min(column, size.columns - 1)
            active.advanceLine(wrapped: nil, eraseStyle: style.eraseStyle, generation: revision)
        }

        /// RI moves up a row, or opens a blank row at the top margin and scrolls the region down.
        mutating func reverseIndex(style: Style) {
            active.column = min(column, size.columns - 1)
            guard row == scrollTop else {
                active.row = max(row - 1, 0)
                return
            }
            revision &+= 1
            active.insertRows(1, at: scrollTop, through: scrollBottom, generation: revision, style: style.eraseStyle)
        }

        /// SU moves the region's rows up without saving them to history.
        mutating func scrollUp(_ count: Int, style: Style) {
            revision &+= 1
            active.deleteRows(count, at: scrollTop, through: scrollBottom, generation: revision,
                              style: style.eraseStyle)
        }

        /// SD opens rows at the top margin. As in the reference, they keep the default background.
        mutating func scrollDown(_ count: Int) {
            revision &+= 1
            active.insertRows(count, at: scrollTop, through: scrollBottom, generation: revision)
        }

        /// IL and DL act only inside the scroll region, and return to the first column there.
        mutating func insertLines(_ count: Int, style: Style) {
            active.column = min(column, size.columns - 1)
            guard (scrollTop...scrollBottom).contains(row) else { return }
            revision &+= 1
            active.insertRows(count, at: row, through: scrollBottom, generation: revision, style: style.eraseStyle)
            active.column = 0
        }

        mutating func deleteLines(_ count: Int, style: Style) {
            active.column = min(column, size.columns - 1)
            guard (scrollTop...scrollBottom).contains(row) else { return }
            revision &+= 1
            active.deleteRows(count, at: row, through: scrollBottom, generation: revision, style: style.eraseStyle)
            active.column = 0
        }

        /// BS moves one column left. With reverse wraparound, it moves from a pending wrap to the last column,
        /// and from the start of a soft-wrapped row inside the region to the end of the row above.
        mutating func backspace(reverseWraparound: Bool) {
            guard reverseWraparound else {
                active.column = max(0, min(column, size.columns - 1) - 1)
                return
            }
            guard column == 0 else {
                active.column = min(column, size.columns) - 1
                return
            }
            let index = active.index(of: row)
            guard row > scrollTop, row <= scrollBottom, active.rows[index].isWrapped else { return }
            revision &+= 1
            active.rows[index].isWrapped = false
            active.rows[index].generation = revision
            active.row -= 1
            active.column = size.columns - 1
            // An empty last cell is the blank a wide character leaves when it wraps early.
            let last = active.rows[active.index(of: row)][column]
            if last.width == 1, last.text.isEmpty { active.column -= 1 }
        }

        // HT, CHT and CBT keep a pending wrap until the next print.
        mutating func horizontalTab(_ count: Int = 1) {
            guard column < size.columns else { return }
            for _ in 0..<min(count, size.columns) {
                active.column = active.tabs.next(after: column, columns: size.columns)
            }
        }

        mutating func backwardTab(_ count: Int) {
            guard column < size.columns else { return }
            for _ in 0..<min(count, size.columns) {
                active.column = active.tabs.previous(before: column, columns: size.columns)
            }
        }

        mutating func setTabStop() { active.tabs.set(column) }

        mutating func clearTabStop() { active.tabs.set(column, false) }

        mutating func clearAllTabStops() { active.tabs.removeAll() }

        private mutating func wrap(style: Style) {
            active.column = 0
            active.advanceLine(wrapped: true, eraseStyle: style.eraseStyle, generation: revision)
        }

        mutating func write(_ scalar: Unicode.Scalar, width: Int, style: Style, wraparound: Bool, insert: Bool,
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

        /// Whether text at the cursor appends cells past those its row uses.
        var appendsAtCursor: Bool { column >= active.rows[active.index(of: row)].length }

        /// Writes glyphs that carry their widths, with autowrap on and insert mode off. Returns how many it wrote.
        mutating func writeRun(_ glyphs: Span<UInt32>, style: Style, joinsPrevious: inout Bool) -> UInt64 {
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
                    write(Unicode.Scalar(glyph.scalar)!, width: width, style: style, wraparound: true, insert: false,
                          joinsPrevious: joinsPrevious)
                    joinsPrevious = width > 0 || joinsPrevious
                    next += 1
                }
            }
            return UInt64(glyphs.count)
        }

        /// REP prints the character left of the cursor again, with its combining marks, in the current style.
        /// It writes at most 65,535 scalars, so a hostile count or cluster can't stall the reader.
        mutating func repeatPrecedingCharacter(_ count: Int, style: Style, wraparound: Bool, insert: Bool) {
            var source = min(column, size.columns) - 1
            guard source >= 0 else { return }
            let line = active.rows[active.index(of: row)]
            if source > 0, line[source].width == 0, line[source].text.isEmpty { source -= 1 }
            let scalars = Array(line[source].text.unicodeScalars)
            guard !scalars.isEmpty else { return }
            for _ in 0..<min(count, 65_535 / scalars.count) {
                for scalar in scalars {
                    write(scalar, width: ColumnWidth.of(scalar), style: style, wraparound: wraparound, insert: insert)
                }
            }
        }

        /// DECALN fills every row with E in the current style. The cursor and margins are the caller's.
        mutating func fillWithAlignmentPattern(style: Style) {
            revision &+= 1
            for line in 0..<size.rows {
                let index = active.index(of: line)
                let pattern = [UInt8](repeating: UInt8(ascii: "E"), count: active.rows[index].storageColumns)
                active.rows[index].writeASCII(pattern.span, at: 0, style: style)
                active.rows[index].isWrapped = false
                active.rows[index].generation = revision
            }
        }

        /// Writes a run of printable ASCII with autowrap on and insert mode off.
        mutating func writeASCII(_ bytes: Span<UInt8>, style: Style) {
            var offset = 0
            while offset < bytes.count {
                revision &+= 1
                if column >= size.columns { wrap(style: style) }
                let count = min(bytes.count - offset, size.columns - column)
                let segment = bytes.extracting(offset..<(offset + count))
                let index = active.index(of: row)
                active.rows[index].writeASCII(segment, at: column, style: style)
                active.rows[index].generation = revision
                active.column += count
                offset += count
            }
        }

        mutating func insertBlanks(_ count: Int, style: Style) {
            editCharacters(.insert, count: count, style: style)
        }

        mutating func deleteCharacters(_ count: Int, style: Style) {
            editCharacters(.delete, count: count, style: style)
        }

        private mutating func editCharacters(_ edit: CharacterEdit, count: Int, style: Style) {
            active.column = min(column, size.columns - 1)
            revision &+= 1
            let index = active.index(of: row)
            active.rows[index].editCharacters(edit, at: column, count: count, style: style.eraseStyle)
            active.rows[index].generation = revision
        }

        /// DECIC, DECDC, SL and SR edit the same columns of every row in the scroll region, and only
        /// while the cursor is inside it. As in the reference, a start past a row's last column wraps to its first.
        mutating func editColumns(_ edit: CharacterEdit, at start: Int, count: Int, style: Style) {
            guard (scrollTop...scrollBottom).contains(row) else { return }
            revision &+= 1
            for line in scrollTop...scrollBottom {
                let index = active.index(of: line)
                let columns = active.rows[index].storageColumns
                active.rows[index].editCharacters(edit, at: start % columns, count: count, style: style.eraseStyle)
                active.rows[index].isWrapped = false
                active.rows[index].generation = revision
            }
        }

        /// ECH blanks cells from the cursor without moving it or the cells after them.
        mutating func eraseCharacters(_ count: Int, style: Style) {
            active.column = min(column, size.columns - 1)
            revision &+= 1
            let index = active.index(of: row)
            let end = min(column + count, active.rows[index].storageColumns)
            active.rows[index].erase(column..<end, style: style.eraseStyle)
            active.rows[index].generation = revision
        }

        /// ED 3 clears history and leaves the screen and saved cursor as they are.
        mutating func eraseHistory() { active.history.removeAll() }

        mutating func eraseLine(_ range: EraseRange, style: Style) {
            active.column = min(column, size.columns)
            revision &+= 1
            let index = active.index(of: row)
            let columns: Range<Int>
            let clearWrap: Bool
            switch range {
            case .toEnd:
                columns = column..<size.columns
                clearWrap = column == 0
            case .toCursor:
                // A pending wrap includes the first hidden column of a narrowed alternate row.
                columns = 0..<min(column + 1, active.rows[index].storageColumns)
                clearWrap = false
            case .entire:
                columns = 0..<size.columns
                clearWrap = true
            }
            active.rows[index].erase(columns, style: style.eraseStyle)
            if clearWrap { active.rows[index].isWrapped = false }
            active.rows[index].generation = revision
        }

        mutating func eraseDisplay(_ range: EraseRange, style: Style) {
            active.column = min(column, size.columns)
            let rows: Range<Int>
            switch range {
            case .toEnd:
                eraseLine(.toEnd, style: style)
                rows = (row + 1)..<size.rows
            case .toCursor:
                eraseLine(.toCursor, style: style)
                active.rows[active.index(of: row)].isWrapped = false
                // An erased right margin breaks the next visible line’s soft wrap.
                if column + 1 >= size.columns, row + 1 < size.rows {
                    let next = active.index(of: row + 1)
                    if active.rows[next].isWrapped {
                        active.rows[next].isWrapped = false
                        active.rows[next].generation = revision
                    }
                }
                rows = 0..<row
            case .entire:
                rows = 0..<size.rows
            }
            revision &+= 1
            for row in rows {
                let index = active.index(of: row)
                // A narrowed alternate row keeps its hidden columns, blanked.
                active.rows[index].clear(columns: active.rows[index].storageColumns, generation: revision,
                                         style: style.eraseStyle)
                active.rows[index].columns = size.columns
            }
        }

        mutating func resize(to size: Size) {
            guard size != active.size else { return }
            alternateCapacity = isAlternate ? size.rows : max(alternateCapacity, size.rows)
            active.resize(to: size, revision: &revision)
            normalWhileAlternate?.resize(to: size, revision: &revision)
        }
    }
}

extension Array {
    /// Moves the elements in `range` toward its end by `offset`, or toward its start when it's negative,
    /// and wraps the elements pushed past one end around to the other.
    ///
    /// The shorter side waits in temporary storage while the rest slides over its slots, then fills the
    /// slots the slide left behind. Each typed move hands its elements to the destination and leaves the
    /// source uninitialized, so every element keeps its one owner and nothing is retained or released.
    /// Nothing between the moves can throw or read the array, and taking the buffer first copies it when
    /// a snapshot shares it.
    fileprivate mutating func rotate(_ range: Range<Int>, by offset: Int) {
        let count = range.count
        guard count > 1 else { return }
        var offset = offset % count
        // Rotating the other way by the rest of the range is the same rotation, so set aside the shorter side.
        if offset > count / 2 { offset -= count } else if offset < -(count / 2) { offset += count }
        guard offset != 0 else { return }
        let shift = abs(offset)
        withUnsafeMutableBufferPointer { buffer in
            let first = buffer.baseAddress! + range.lowerBound, last = first + count - shift
            withUnsafeTemporaryAllocation(of: Element.self, capacity: shift) { aside in
                let aside = aside.baseAddress!
                if offset < 0 {
                    aside.moveInitialize(from: first, count: shift)
                    first.moveInitialize(from: first + shift, count: count - shift)
                    last.moveInitialize(from: aside, count: shift)
                } else {
                    aside.moveInitialize(from: last, count: shift)
                    (first + shift).moveInitialize(from: first, count: count - shift)
                    first.moveInitialize(from: aside, count: shift)
                }
            }
        }
    }
}
