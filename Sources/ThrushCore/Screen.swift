extension Terminal {
    /// The oldest row is always at index zero, including after the backing array wraps.
    package struct History: RandomAccessCollection, Sendable {
        private var storage: [Row] = []
        private var head = 0
        package private(set) var evictedRows = 0
        static let limit = 1_000
        let capacity: Int

        init(capacity: Int = Self.limit) { self.capacity = capacity }

        package var startIndex: Int { 0 }
        package var endIndex: Int { storage.count }
        package subscript(index: Int) -> Row {
            precondition(indices.contains(index))
            return storage[(head + index) % storage.count]
        }

        mutating func append(_ row: Row) {
            guard capacity > 0 else { return }
            if storage.count == capacity {
                evictedRows += 1
                storage[head] = row
                head += 1
                if head == capacity { head = 0 }
            } else {
                storage.append(row)
            }
        }
    }

    package struct Snapshot: Sendable {
        package let size: Size
        package let palette: Palette
        package let modes: Modes
        package private(set) var rows: [Row]
        package let history: History
        package let normalHistoryCount: Int
        package private(set) var cursorRow: Int
        package let cursorColumn: Int
        package private(set) var cursorVisible: Bool
        package let cursorBlink: Bool
        package let cursorShape: CursorShape
        package let isAlternate: Bool
        package let generation: UInt64
        /// A presenter can coalesce these snapshots and release the most recent one on reset or timeout.
        package var synchronizedOutputID: UInt64? { modes.synchronizedOutputID }

        /// Zero is the oldest retained row. The first live row follows the active history.
        package func row(atAbsoluteIndex index: Int) -> Row {
            index < history.count ? history[index] : rows[index - history.count]
        }
        package var mouseTracking: MouseTracking { modes.mouseTracking }

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
    }

    /// A rotating viewport makes the usual full-height scroll O(1), independent of scrollback.
    struct Buffer: Sendable {
        var size: Size
        var rows: [Row]
        var head = 0
        var history = History()
        var row = 0
        var column = 0
        var savedRow = 0  // Absolute, including history, as in the reference buffer.
        var savedColumn = 0
        var scrollTop = 0
        var scrollBottom: Int
        let alternate: Bool

        init(size: Size, alternate: Bool = false, generation: UInt64 = 0, style: Style = .init(),
             historyCapacity: Int = History.limit) {
            self.size = size
            self.alternate = alternate
            history = History(capacity: historyCapacity)
            rows = Array(repeating: Row(columns: size.columns, generation: generation, style: style), count: size.rows)
            scrollBottom = size.rows - 1
        }

        func index(of row: Int) -> Int {
            let offset = head + row
            return offset >= rows.count ? offset - rows.count : offset
        }

        var visible: [Row] {
            head == 0 ? rows : Array(rows[head...] + rows[..<head])
        }

        mutating func advanceLine(wrapped: Bool, eraseStyle: Style, generation: UInt64) {
            if row != scrollBottom {
                let next = min(row + 1, size.rows - 1)
                if wrapped || next != row {
                    let index = index(of: next)
                    if rows[index].isWrapped != wrapped {
                        rows[index].isWrapped = wrapped
                        rows[index].generation = generation
                    }
                }
                row = next
                return
            }

            let blank = Row(columns: size.columns, generation: generation, style: eraseStyle, wrapped: wrapped)
            if scrollTop == 0 {
                history.append(rows[head])
                if scrollBottom == size.rows - 1 {
                    rows[head] = blank
                    head += 1
                    if head == size.rows { head = 0 }
                    return
                }
            }

            for y in scrollTop..<scrollBottom {
                let destination = index(of: y)
                let source = index(of: y + 1)
                rows[destination] = rows[source]
            }
            rows[index(of: scrollBottom)] = blank
        }
    }

    package struct Screen: Sendable {
        private var active: Buffer
        private var normalWhileAlternate: Buffer?
        // The reference retains its empty alternate buffer’s row capacity across an inactive shrink.
        private var alternateCapacity: Int
        private var revision: UInt64 = 0

        var row: Int { active.row }
        var column: Int { active.column }
        var size: Size { active.size }
        var scrollTop: Int { active.scrollTop }
        var scrollBottom: Int { active.scrollBottom }
        var isAlternate: Bool { active.alternate }

        init(size: Size) {
            active = Buffer(size: size)
            alternateCapacity = size.rows
        }

        func snapshot(generation: UInt64, modes: Modes, palette: Palette) -> Snapshot {
            Snapshot(size: size, palette: palette, modes: modes, rows: active.visible, history: active.history,
                     normalHistoryCount: normalWhileAlternate?.history.count ?? active.history.count,
                     cursorRow: row, cursorColumn: column, cursorVisible: modes.cursorVisible,
                     cursorBlink: modes.cursorBlinkOverride ?? modes.cursorBlink, cursorShape: modes.cursorShape,
                     isAlternate: isAlternate, generation: generation)
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
            } else if let normalWhileAlternate {
                alternateCapacity = size.rows
                active = normalWhileAlternate
                self.normalWhileAlternate = nil
            }
            active.row = row
            active.column = column
        }

        mutating func saveCursor() {
            active.savedRow = active.history.count + row
            active.savedColumn = column
        }

        mutating func restoreCursor() {
            move(toRow: active.savedRow - active.history.count, column: active.savedColumn)
        }

        mutating func move(toRow row: Int, column: Int) {
            active.row = min(max(0, row), size.rows - 1)
            active.column = min(max(0, column), size.columns - 1)
        }

        mutating func setScrollRegion(top: Int, bottom: Int) {
            if top >= 0, top < bottom, bottom < size.rows {
                active.scrollTop = top
                active.scrollBottom = bottom
            }
        }

        mutating func carriageReturn() { active.column = 0 }

        mutating func lineFeed(style: Style = .init()) {
            revision &+= 1
            if column >= size.columns { active.column -= 1 }
            active.advanceLine(wrapped: false, eraseStyle: style.eraseStyle, generation: revision)
        }

        mutating func backspace() { active.column = max(0, min(column, size.columns - 1) - 1) }

        private mutating func wrap(style: Style) {
            active.column = 0
            active.advanceLine(wrapped: true, eraseStyle: style.eraseStyle, generation: revision)
        }

        mutating func write(_ scalar: Unicode.Scalar, width: Int, style: Style, joinsPrevious: Bool = true) {
            revision &+= 1
            if width == 0, joinsPrevious, column > 0 {
                let index = active.index(of: row)
                active.rows[index].appendCombining(scalar, before: column)
                active.rows[index].generation = revision
                return
            }
            if column + width > size.columns {
                if column < size.columns {
                    let index = active.index(of: row)
                    active.rows[index].erase(column..<size.columns, style: style)
                    active.rows[index].generation = revision
                    revision &+= 1
                }
                wrap(style: style)
            }
            let index = active.index(of: row)
            if column < active.rows[index].storageColumns {
                active.rows[index].write(scalar, at: column, width: width, style: style)
                active.rows[index].generation = revision
            }
            // A standalone combining mark occupies a cell of width zero. At the pending wrap
            // margin xterm advances its cursor even though no visible cell receives the mark.
            active.column += max(1, width)
        }

        mutating func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, style: Style) {
            var offset = 0
            while offset < bytes.count {
                revision &+= 1
                if column >= size.columns { wrap(style: style) }
                let count = min(bytes.count - offset, size.columns - column)
                let segment = UnsafeBufferPointer(rebasing: bytes[offset..<(offset + count)])
                let index = active.index(of: row)
                active.rows[index].writeASCII(segment, at: column, style: style)
                active.rows[index].generation = revision
                active.column += count
                offset += count
            }
        }

        mutating func eraseLine(_ mode: Int, style: Style) {
            guard mode == 0 else { return }  // The recorded editor clears from its cursor to the margin.
            active.column = min(column, size.columns)
            revision &+= 1
            let index = active.index(of: row)
            active.rows[index].erase(min(column, size.columns)..<size.columns, style: style.eraseStyle)
            if column == 0 { active.rows[index].isWrapped = false }
            active.rows[index].generation = revision
        }

        mutating func eraseDisplay(_ mode: Int, style: Style) {
            let firstRow: Int
            switch mode {
            case 0:
                eraseLine(0, style: style)
                firstRow = row + 1
            case 2:
                firstRow = 0
            default:
                return
            }
            active.column = min(column, size.columns)
            revision &+= 1
            let blank = Row(columns: size.columns, generation: revision, style: style.eraseStyle)
            if firstRow == 0 && !isAlternate {
                active.rows = Array(repeating: blank, count: size.rows)
                active.head = 0
                return
            }
            for row in firstRow..<size.rows {
                let index = active.index(of: row)
                let width = active.rows[index].storageColumns
                active.rows[index] = width == size.columns ? blank
                    : Row(columns: width, generation: revision, style: style.eraseStyle)
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
