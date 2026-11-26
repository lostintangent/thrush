// Reflows soft-wrapped lines on the normal screen when the column count changes.
// The alternate screen keeps fixed row positions so an application can redraw its layout.

extension Terminal.Buffer {
    mutating func resize(to newSize: Terminal.Size, revision: inout UInt64) {
        let archived = history.previousShellCount
        guard archived > 0 else {
            resizeCurrentShell(to: newSize, revision: &revision)
            return
        }
        // The new program can draw only on its own screen. A taller viewport must never
        // pull an older shell's lines into it, even when the cursor is at the bottom.
        let earlier = history.retainingPreviousShells()
        history = Terminal.History(history.dropFirst(archived))
        let oldColumns = size.columns
        resizeCurrentShell(to: newSize, revision: &revision)
        prependPreviousShells(earlier, fromColumns: oldColumns, revision: &revision)
    }

    mutating func prependPreviousShells(_ earlier: Terminal.History, fromColumns columns: Int,
                                        revision: inout UInt64) {
        guard !earlier.isEmpty else { return }
        var combined = earlier
        if columns != size.columns {
            // A blank live row leaves every line of the old transcript eligible for reflow.
            var transcript = Self(size: .init(columns: columns, rows: 1))
            transcript.history = earlier
            transcript.resizeCurrentShell(to: .init(columns: size.columns, rows: 1), revision: &revision)
            combined = transcript.history
        }
        combined.markPreviousShells()
        for var row in history { combined.append(&row) }
        history = combined
    }

    private mutating func resizeCurrentShell(to newSize: Terminal.Size, revision: inout UInt64) {
        let generation = revision
        let oldSize = size
        let blank = Terminal.Row(columns: newSize.columns, generation: generation)
        var base = history.count
        var lines = Array(history) + visible
        let historyLimit = alternate ? 0 : Terminal.History.limit

        // A taller screen pulls from history when the cursor is on the bottom row.
        // A shorter screen discards rows below the cursor before it scrolls the cursor into view.
        if newSize.rows > oldSize.rows {
            for _ in oldSize.rows..<newSize.rows {
                if base > 0, base + row + 1 == lines.count {
                    base -= 1
                    row += 1
                } else {
                    // On an alternate buffer with surplus capacity, the reference's intermediate
                    // circular list can already be full before it adjusts to the new row count.
                    if alternate, lines.count == max(oldSize.rows + history.capacity, newSize.rows) {
                        lines.removeFirst()
                    }
                    lines.append(blank)
                }
            }
        } else if newSize.rows < oldSize.rows {
            for _ in newSize.rows..<oldSize.rows {
                if lines.count > base + row + 1 { lines.removeLast() }
                else { base += 1 }
            }
        }
        let maxCount = historyLimit + newSize.rows
        if lines.count > maxCount {
            let trim = lines.count - maxCount
            lines.removeFirst(trim)
            base = max(0, base - trim)
            saved.row = max(0, saved.row - trim)
        }
        column = min(column, newSize.columns - 1)
        saved.column = min(saved.column, newSize.columns - 1)
        row = min(row, newSize.rows - 1)

        if oldSize.columns != newSize.columns {
            if alternate {
                // Shrinking the alternate buffer preserves its off-screen columns.
                // Growing can expose them again until the application repaints.
                for index in lines.indices {
                    if newSize.columns > oldSize.columns { lines[index].truncate(to: newSize.columns) }
                    lines[index].columns = newSize.columns
                    lines[index].generation = generation
                }
            } else if newSize.columns < oldSize.columns {
                reflowNarrower(&lines, base: &base, oldWidth: oldSize.columns, newSize: newSize,
                               maxCount: maxCount, generation: generation)
            } else {
                let oldCount = lines.count
                lines = reflowWider(lines, oldWidth: oldSize.columns, newWidth: newSize.columns,
                                    cursor: base + row, generation: generation)
                // Joined rows leave history first, and then pull the cursor up.
                let removed = oldCount - lines.count
                row = max(0, row - max(0, removed - base))
                saved.row = max(0, saved.row - removed)
            }
        }

        // A previously inactive alternate buffer may report a history row but omit the last
        // viewport slot after a height change. Materialize that missing display row as a blank.
        let required = newSize.rows + (alternate ? base : 0)
        if lines.count < required {
            lines.append(contentsOf: repeatElement(blank, count: required - lines.count))
        }
        // Distinct row generations let a renderer recognize moving lines after the next scroll.
        for index in lines.indices {
            revision &+= 1
            lines[index].generation = revision
        }
        let historyEnd = lines.count - newSize.rows
        let retained = alternate ? base : historyLimit
        history = Terminal.History(capacity: retained)
        for var line in lines[max(0, historyEnd - retained)..<historyEnd] { history.append(&line) }
        rows = Array(lines[historyEnd...])
        order = Array(rows.indices)
        head = 0
        size = newSize
        scrollTop = 0
        scrollBottom = newSize.rows - 1
        tabs.resize(to: newSize.columns)
    }

    /// A logical line comprises its first physical row and all immediately following soft wraps.
    /// Widening joins each logical line's rows and drops the rows it empties. The pinned server
    /// leaves the cursor's logical line for the application to repaint.
    private func reflowWider(
        _ lines: [Terminal.Row], oldWidth: Int, newWidth: Int, cursor: Int, generation: UInt64
    ) -> [Terminal.Row] {
        var result: [Terminal.Row] = []
        result.reserveCapacity(lines.count)
        var start = 0
        while start < lines.count {
            var end = start + 1
            while end < lines.count, lines[end].isWrapped { end += 1 }
            let group = start..<end
            if group.count == 1 || group.contains(cursor) {
                for var line in lines[group] {
                    line.truncate(to: newWidth)
                    result.append(line)
                }
            } else {
                let first = result.count
                appendReflowed(lines[group], oldWidth: oldWidth, newWidth: newWidth, generation: generation, to: &result)
                while result.count > first + 1, result.last!.trimmedLength == 0 { result.removeLast() }
            }
            start = end
        }
        return result
    }

    /// Work up from the bottom so each expansion can move the cursor before we visit the
    /// next line. Keep new rows at their original insertion points until the viewport settles.
    private mutating func reflowNarrower(
        _ lines: inout [Terminal.Row], base: inout Int, oldWidth: Int, newSize: Terminal.Size,
        maxCount: Int, generation: UInt64
    ) {
        var insertions: [(boundary: Int, rows: [Terminal.Row])] = []
        var retainedExtras = 0
        var end = lines.count
        while end > 0 {
            let last = end - 1
            var start = last
            while start > 0, lines[start].isWrapped { start -= 1 }
            let group = start..<end
            end = start
            guard lines[last].isWrapped || lines[last].trimmedLength > newSize.columns,
                  !group.contains(base + row) else { continue }

            let layout = narrowed(lines[group], oldWidth: oldWidth, newWidth: newSize.columns,
                                  roomForExtras: maxCount - retainedExtras, generation: generation)
            for (offset, line) in layout.originals.enumerated() { lines[start + offset] = line }
            if !layout.extras.isEmpty {
                insertions.append((group.upperBound, layout.extras))
                retainedExtras += layout.extras.count
            }

            // With no scrollback, move the cursor down and discard that many original
            // viewport rows from the bottom. Any remaining expansion enters scrollback.
            let growth = max(0, layout.growth)
            let cursorShift = base == 0 ? min(growth, newSize.rows - 1 - row) : 0
            row += cursorShift
            lines.removeLast(cursorShift)
            let historyRoom = Terminal.History.limit - base
            base += min(growth - cursorShift, historyRoom)
            saved.row = min(saved.row + layout.growth, base + newSize.rows - 1)
            end = min(end, lines.count)
        }

        if !insertions.isEmpty {
            var expanded: [Terminal.Row] = []
            expanded.reserveCapacity(lines.count + retainedExtras)
            var next = 0
            for insertion in insertions.reversed() {
                // A removed original row can still have additional wrapped rows after it.
                let boundary = min(insertion.boundary, lines.count)
                expanded.append(contentsOf: lines[next..<boundary])
                expanded.append(contentsOf: insertion.rows)
                next = boundary
            }
            expanded.append(contentsOf: lines[next...])
            expanded.removeFirst(max(0, expanded.count - maxCount))
            lines = expanded
        }
        for index in lines.indices { lines[index].truncate(to: newSize.columns) }
    }

    /// A logical line first rewrites its original rows, then adds wrapped rows.
    /// A wide glyph that would straddle an edge starts on the next row.
    private func narrowed(
        _ group: ArraySlice<Terminal.Row>, oldWidth: Int, newWidth: Int, roomForExtras: Int, generation: UInt64
    ) -> (originals: [Terminal.Row], extras: [Terminal.Row], growth: Int) {
        var used = group.indices.map { usedLength(of: group, at: $0, width: oldWidth) }
        // A wide glyph that a narrower screen cut from the last column takes back its second half.
        if group.last!.stored(at: oldWidth - 1).width == 2 { used[used.count - 1] += 1 }
        let needed = used.reduce(0, +)
        var lengths: [Int] = []
        var laidOut = 0
        var line = 0
        var column = 0
        while laidOut < needed {
            if needed - laidOut < newWidth {
                lengths.append(needed - laidOut)
                break
            }
            column += newWidth
            if column > used[line] {
                column -= used[line]
                line += 1
            }
            let straddles = group[group.startIndex + line].stored(at: column - 1).width == 2
            if straddles { column -= 1 }
            lengths.append(straddles ? newWidth - 1 : newWidth)
            laidOut += lengths.last!
        }

        let growth = lengths.count - group.count
        // Skip rows that will fall off the top of history. Later lines have already
        // claimed their extra rows, and this line's last rows are the next to keep.
        let first = growth > roomForExtras ? lengths.count - roomForExtras : 0
        var originals: [Terminal.Row] = []
        var extras: [Terminal.Row] = []
        var source = 0
        var sourceColumn = lengths[..<first].reduce(0, +)
        for offset in first..<lengths.count {
            let length = lengths[offset]
            var row = offset < group.count
                ? group[group.startIndex + offset]
                : Terminal.Row(columns: newWidth, generation: generation, wrapped: true)
            var column = 0
            while column < length {
                while sourceColumn >= used[source] {
                    sourceColumn -= used[source]
                    source += 1
                }
                let count = min(length - column, used[source] - sourceColumn)
                if source != offset || sourceColumn != column {
                    row.copy(sourceColumn..<(sourceColumn + count), from: group[group.startIndex + source], to: column)
                }
                column += count
                sourceColumn += count
                if sourceColumn > oldWidth { row.restoreContinuation(at: column - 1) }
            }
            // Only the cell after a short row is blanked. A wide glyph before it stays, even one a
            // narrower screen left without its second half.
            if length < newWidth { row.fillWithBlanks(length..<(length + 1)) }
            if offset < group.count { originals.append(row) } else { extras.append(row) }
        }
        return (originals, extras, growth)
    }

    /// The cells a row contributes to its logical line. A continued row runs to the edge, or stops
    /// one cell short when a wide glyph wrapped from its last column. The last row ends at its text.
    private func usedLength(of group: ArraySlice<Terminal.Row>, at index: Int, width: Int) -> Int {
        if index + 1 == group.endIndex { return group[index].trimmedLength }
        let wideWrapped = group[index].stored(at: width - 1).glyph == 0 && group[index + 1].stored(at: 0).width == 2
        return wideWrapped ? width - 1 : width
    }

    /// Joins a logical line's rows at a wider width.
    private func appendReflowed(
        _ source: ArraySlice<Terminal.Row>, oldWidth: Int, newWidth: Int,
        generation: UInt64, to result: inout [Terminal.Row]
    ) {
        var dest = Terminal.Row(columns: newWidth, generation: generation, wrapped: source.first!.isWrapped)
        var used = 0
        for index in source.indices {
            let line = source[index]
            let end = usedLength(of: source, at: index, width: oldWidth)
            var column = 0
            while column < end {
                var count = min(end - column, newWidth - used)
                if count > 0, used + count == newWidth, line.stored(at: column + count - 1).width == 2 {
                    count -= 1
                }
                if count > 0 {
                    dest.copy(column..<(column + count), from: line, to: used)
                    used += count
                    column += count
                }
                if column < end {
                    result.append(dest)
                    dest = Terminal.Row(columns: newWidth, generation: generation, wrapped: true)
                    used = 0
                }
            }
        }
        result.append(dest)
    }
}
