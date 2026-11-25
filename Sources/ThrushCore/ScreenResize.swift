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
            savedRow = max(0, savedRow - trim)
        }
        column = min(column, newSize.columns - 1)
        savedColumn = min(savedColumn, newSize.columns - 1)
        row = min(row, newSize.rows - 1)

        if oldSize.columns != newSize.columns {
            if alternate {
                // xterm leaves off-screen columns of the alternate buffer intact on shrink.
                // Growing can expose them again until the application repaints.
                for index in lines.indices {
                    if newSize.columns > oldSize.columns { lines[index].truncate(to: newSize.columns) }
                    lines[index].columns = newSize.columns
                    lines[index].generation = generation
                }
            } else {
                let oldCount = lines.count
                lines = reflow(lines, oldWidth: oldSize.columns, newWidth: newSize.columns,
                               cursor: base + row, newRows: newSize.rows, generation: generation)
                let delta = lines.count - oldCount
                if delta > 0 {
                    // Reflow consumes unused space below the cursor first, and then creates history.
                    let spare = base == 0 ? min(delta, newSize.rows - row - 1) : 0
                    if spare > 0 { lines.removeLast(spare); row += spare }
                    savedRow = min(savedRow + delta, lines.count - 1)
                } else if delta < 0 {
                    row = max(0, row - max(0, -delta - base))
                    savedRow = max(0, savedRow + delta)
                }
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
        for line in lines[max(0, historyEnd - retained)..<historyEnd] { history.append(line) }
        rows = Array(lines[historyEnd...])
        head = 0
        size = newSize
        scrollTop = 0
        scrollBottom = newSize.rows - 1
    }

    /// A logical line comprises its first physical row and all immediately following soft wraps.
    /// The pinned server leaves the cursor's logical line for the application to repaint.
    private func reflow(
        _ lines: [Terminal.Row], oldWidth: Int, newWidth: Int, cursor: Int, newRows: Int, generation: UInt64
    ) -> [Terminal.Row] {
        var groups: [[Terminal.Row]] = []
        var end = lines.count
        var referenceCursor = cursor
        let shrinking = newWidth < oldWidth
        // Shrinking the layout pushes the viewport down as each logical line expands.
        // The server tests the current cursor position while it works upwards from the bottom.
        while end > 0 {
            var start = end - 1
            while start > 0, lines[start].isWrapped { start -= 1 }
            let group = start..<end
            let needsLayout = group.count > 1 || lines[start].trimmedLength > newWidth
            var updated: [Terminal.Row] = []
            if group.contains(referenceCursor) || !needsLayout {
                for index in group {
                    var line = lines[index]
                    line.truncate(to: newWidth)
                    line.generation = generation
                    updated.append(line)
                }
            } else {
                appendReflowed(lines[group], oldWidth: oldWidth, newWidth: newWidth,
                               generation: generation, to: &updated)
                if !shrinking {
                    while updated.count > 1, updated.last!.trimmedLength == 0 { updated.removeLast() }
                }
            }
            if shrinking {
                referenceCursor = min(Terminal.History.limit + newRows - 1,
                                      referenceCursor + max(0, updated.count - group.count))
            }
            groups.append(updated)
            end = start
        }
        return groups.reversed().flatMap { $0 }
    }

    private func appendReflowed(
        _ source: ArraySlice<Terminal.Row>, oldWidth: Int, newWidth: Int,
        generation: UInt64, to result: inout [Terminal.Row]
    ) {
        var dest = Terminal.Row(columns: newWidth, generation: generation, wrapped: source.first!.isWrapped)
        var used = 0
        for index in source.indices {
            let line = source[index]
            let end: Int
            if index + 1 == source.endIndex {
                end = line.trimmedLength
            } else if line.stored(at: oldWidth - 1).glyph == 0, source[index + 1].stored(at: 0).width == 2 {
                // A wide glyph that wrapped from the last column left one unoccupied cell behind.
                end = oldWidth - 1
            } else {
                end = oldWidth
            }
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
