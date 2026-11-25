// Reflows soft-wrapped lines on the normal screen when the column count changes.
// The alternate screen keeps fixed row positions so an application can redraw its layout.

extension Terminal.Buffer {
    mutating func resize(to newSize: Terminal.Size, revision: inout UInt64) {
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

    /// Narrowing works up from the bottom, as the pinned server does. Each logical line that no
    /// longer fits is laid out again over its own rows, and the rows it adds are inserted after the
    /// pass. Making room for them moves the cursor down by removing rows from the bottom, so a line
    /// below can disappear while the added rows of a line above it survive.
    private mutating func reflowNarrower(
        _ lines: inout [Terminal.Row], base: inout Int, oldWidth: Int, newSize: Terminal.Size,
        maxCount: Int, generation: UInt64
    ) {
        var insertions: [(index: Int, rows: [Terminal.Row])] = []
        var inserted = 0
        var index = lines.count - 1
        while index >= 0 {
            defer { index -= 1 }
            guard index < lines.count, lines[index].isWrapped || lines[index].trimmedLength > newSize.columns else {
                continue
            }
            let end = index + 1
            while index > 0, lines[index].isWrapped { index -= 1 }
            let group = index..<end
            if group.contains(base + row) { continue }

            let layout = narrowed(lines[group], oldWidth: oldWidth, newWidth: newSize.columns, generation: generation)
            let added = layout.count - group.count
            // Rows past the history limit leave from the top, so they need no room.
            let overflow = base == 0 && row != lines.count - 1
                ? row - maxCount + added : lines.count - maxCount + added
            for (offset, line) in layout.prefix(group.count).enumerated() { lines[index + offset] = line }
            if added > 0 {
                insertions.append((end + inserted, Array(layout[group.count...])))
                inserted += added
            }
            for _ in 0..<max(0, added - max(0, overflow)) {
                if base > 0 {
                    if base < min(maxCount, lines.count + inserted) - newSize.rows { base += 1 }
                } else if row < newSize.rows - 1 {
                    row += 1
                    lines.removeLast()
                } else {
                    base += 1
                }
            }
            saved.row = min(saved.row + added, base + newSize.rows - 1)
        }

        if !insertions.isEmpty {
            // Fill from the bottom, so rows past the history limit fall off the top.
            let count = min(maxCount, lines.count + inserted)
            var rearranged: [Terminal.Row] = []
            rearranged.reserveCapacity(count)
            var source = lines.count - 1
            var next = 0
            var placed = 0
            while rearranged.count < count {
                if next < insertions.count, source < 0 || insertions[next].index > source + placed {
                    rearranged.append(contentsOf: insertions[next].rows.reversed().prefix(count - rearranged.count))
                    placed += insertions[next].rows.count
                    next += 1
                } else {
                    rearranged.append(lines[source])
                    source -= 1
                }
            }
            lines = rearranged.reversed()
        }
        for index in lines.indices { lines[index].truncate(to: newSize.columns) }
    }

    /// Lays a logical line out again at a narrower width over its own rows, then new ones. Its rows
    /// keep any cells past the new text, as the server rewrites them in place. A row ends one cell
    /// early when a wide glyph would straddle its edge.
    private func narrowed(
        _ group: ArraySlice<Terminal.Row>, oldWidth: Int, newWidth: Int, generation: UInt64
    ) -> [Terminal.Row] {
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

        var result: [Terminal.Row] = []
        var source = 0
        var sourceColumn = 0
        for (offset, length) in lengths.enumerated() {
            var row = offset < group.count
                ? group[group.startIndex + offset]
                : Terminal.Row(columns: newWidth, generation: generation, wrapped: true)
            var column = 0
            while column < length {
                while sourceColumn == used[source] {
                    source += 1
                    sourceColumn = 0
                }
                let count = min(length - column, used[source] - sourceColumn)
                row.copy(sourceColumn..<(sourceColumn + count), from: group[group.startIndex + source], to: column)
                column += count
                sourceColumn += count
                if sourceColumn > oldWidth { row.restoreContinuation(at: column - 1) }
            }
            // Only the cell after a short row is blanked. A wide glyph before it stays, even one a
            // narrower screen left without its second half.
            if length < newWidth { row.fillWithBlanks(length..<(length + 1)) }
            result.append(row)
        }
        return result
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
