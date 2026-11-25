// A row stores each glyph in an 8-byte cell with its width and the position of its style in a
// short list the row keeps. Only glyphs with combining marks need a separate string.

extension Terminal {
    enum CharacterEdit { case insert, delete }

    package enum Color: Equatable, Sendable {
        case `default`, indexed(UInt8), rgb(UInt8, UInt8, UInt8)

        /// The case in the top byte and its components in the low three, so the default is zero.
        fileprivate init(bits: UInt32) {
            switch bits >> 24 {
            case 1: self = .indexed(UInt8(truncatingIfNeeded: bits))
            case 2: self = .rgb(UInt8(truncatingIfNeeded: bits >> 16), UInt8(truncatingIfNeeded: bits >> 8),
                                UInt8(truncatingIfNeeded: bits))
            default: self = .default
            }
        }

        fileprivate var bits: UInt32 {
            switch self {
            case .default: 0
            case .indexed(let index): 1 << 24 | UInt32(index)
            case .rgb(let red, let green, let blue): 2 << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
            }
        }
    }

    /// A style packs both colors and the rendition flags into one integer, so the default style
    /// is zero and comparing two styles is a single compare.
    package struct Style: Equatable, Sendable {
        // The foreground in the low 26 bits, the background in the next 26 and the flags above them.
        private var bits: UInt64 = 0
        private static let color: UInt64 = 1 << 26 - 1
        private static let background = 26
        private static let flags = 52

        package init() {}

        package var foreground: Color {
            get { Color(bits: UInt32(truncatingIfNeeded: bits & Self.color)) }
            set { bits = bits & ~Self.color | UInt64(newValue.bits) }
        }

        package var background: Color {
            get { Color(bits: UInt32(truncatingIfNeeded: bits >> Self.background & Self.color)) }
            set { bits = bits & ~(Self.color << Self.background) | UInt64(newValue.bits) << Self.background }
        }

        private subscript(bit: UInt64) -> Bool {
            get { bits & bit << Self.flags != 0 }
            set { if newValue { bits |= bit << Self.flags } else { bits &= ~(bit << Self.flags) } }
        }

        package var bold: Bool { get { self[1] } set { self[1] = newValue } }
        package var dim: Bool { get { self[2] } set { self[2] = newValue } }
        package var italic: Bool { get { self[4] } set { self[4] = newValue } }
        package var underline: Bool { get { self[8] } set { self[8] = newValue } }
        package var blink: Bool { get { self[16] } set { self[16] = newValue } }
        package var inverse: Bool { get { self[32] } set { self[32] = newValue } }
        package var invisible: Bool { get { self[64] } set { self[64] = newValue } }
        package var strikethrough: Bool { get { self[128] } set { self[128] = newValue } }

        var isDefault: Bool { bits == 0 }

        /// Erased cells use the current background color with default rendition.
        var eraseStyle: Self {
            var result = Self()
            result.bits = bits & Self.color << Self.background
            return result
        }
    }

    package struct Cell: Equatable, Sendable {
        package let text: String
        package let width: Int
        package let style: Style
    }

    /// A cell is 8 bytes of plain data, so a blank cell in the default style is all zero bits.
    struct StoredCell: Sendable {
        static let wide: UInt32 = 1 << 21
        static let continuation: UInt32 = 1 << 22
        static let zeroWidth: UInt32 = 1 << 23
        /// A scalar in the low 21 bits, with the width flags above it.
        var glyph: UInt32 = 0
        /// Zero is the default style. Any other value `n` is `styles[n - 1]` in the cell's row.
        var style: UInt32 = 0

        var scalar: UInt32 { glyph & 0x1f_ffff }
        var width: Int {
            if glyph & Self.wide != 0 { return 2 }
            return glyph & (Self.continuation | Self.zeroWidth) == 0 ? 1 : 0
        }
    }

    package struct Row: Sendable {
        package internal(set) var isWrapped = false
        package internal(set) var generation: UInt64
        var columns: Int
        // Narrowing an alternate screen leaves the original row slots available on widening.
        var storageColumns: Int
        // Cells up to the last one written. Columns past the end are blank in the default style.
        // The first write reserves the full width, so extending a row never reallocates.
        var cells: [StoredCell]
        // The styles the cells use other than the default. An entry can repeat, and it can stay
        // after its last cell changes until the list is compacted.
        private(set) var styles: [Style] = []
        var clusters: [Int: String] = [:]

        init(columns: Int, generation: UInt64, style: Style = .init(), wrapped: Bool = false) {
            self.columns = columns
            storageColumns = columns
            self.generation = generation
            self.isWrapped = wrapped
            cells = []
            fill(with: style)
        }

        /// Makes this row equal to `Row(columns:generation:style:wrapped:)` but keeps its storage,
        /// so a recycled row takes its next line without allocating.
        mutating func clear(columns: Int, generation: UInt64, style: Style = .init(), wrapped: Bool = false) {
            self.columns = columns
            storageColumns = columns
            self.generation = generation
            isWrapped = wrapped
            // A snapshot that still shares the cells or styles keeps them, and this row gets new storage.
            cells.removeAll(keepingCapacity: true)
            if !styles.isEmpty { styles.removeAll(keepingCapacity: true) }
            if !clusters.isEmpty { clusters.removeAll() }
            fill(with: style)
        }

        // Default blanks stay implied. A blank row in any other style stores every column.
        private mutating func fill(with style: Style) {
            guard style != Style() else { return }
            styles.append(style)
            cells.append(contentsOf: repeatElement(StoredCell(style: 1), count: columns))
        }

        func stored(at column: Int) -> StoredCell {
            column < cells.count ? cells[column] : StoredCell()
        }

        func style(of cell: StoredCell) -> Style {
            cell.style == 0 ? Style() : styles[Int(cell.style) - 1]
        }

        package subscript(column: Int) -> Cell {
            precondition((0..<columns).contains(column))
            let cell = stored(at: column)
            let text = clusters[column] ?? (cell.scalar == 0 ? "" : String(Unicode.Scalar(cell.scalar)!))
            return Cell(text: text, width: cell.width, style: style(of: cell))
        }

        package var trimmedLength: Int {
            var length = cells.count
            while length > 0 {
                let cell = cells[length - 1]
                if cell.scalar != 0 { return min(columns, length - 1 + cell.width) }
                length -= 1
            }
            return 0
        }

        package var text: String {
            var result = ""
            let length = trimmedLength
            result.reserveCapacity(length)
            var index = 0
            while index < length {
                let cell = stored(at: index)
                if let cluster = clusters[index] {
                    result.append(contentsOf: cluster)
                } else {
                    result.unicodeScalars.append(Unicode.Scalar(cell.scalar == 0 ? 32 : cell.scalar)!)
                }
                index += max(1, cell.width)
            }
            return result
        }

        mutating func ensureLength(_ length: Int) {
            guard cells.count < length else { return }
            reserveWidth()
            let count = length - cells.count
            cells.append(addingCapacity: count) { $0.append(repeating: StoredCell(), count: count) }
        }

        // A row shared with a snapshot keeps this capacity when its first write copies it.
        private mutating func reserveWidth() {
            if cells.capacity < storageColumns { cells.reserveCapacity(storageColumns) }
        }

        /// Returns the position a cell stores for `style`. Text changes style far less often than
        /// it prints a cell, so the default style and the last one added cover nearly every lookup.
        /// Any other style is appended, even if an older entry matches.
        private mutating func position(of style: Style) -> UInt32 {
            if style.isDefault { return 0 }
            if styles.last == style { return UInt32(styles.count) }
            if styles.count == styles.capacity { makeRoomForStyle() }
            styles.append(style)
            return UInt32(styles.count)
        }

        /// A full list twice the row's width drops the styles no cell uses, so it never outgrows
        /// the row. Most rows use a few styles. A row that needs more probably changes style every
        /// few cells, so its list grows straight to the row's width.
        @inline(never)
        private mutating func makeRoomForStyle() {
            if styles.count >= 2 * storageColumns {
                compactStyles()
            } else {
                styles.reserveCapacity(styles.isEmpty ? 8 : max(storageColumns, 2 * styles.count))
            }
        }

        /// Keeps the styles that cells still use, in order, and renumbers the cells to match.
        private mutating func compactStyles() {
            withUnsafeTemporaryAllocation(of: UInt32.self, capacity: styles.count + 1) { renumbered in
                renumbered.initialize(repeating: 0)
                for cell in cells { renumbered[Int(cell.style)] = 1 }
                renumbered[0] = 0
                var kept = 0
                for position in 1..<renumbered.count where renumbered[position] != 0 {
                    styles[kept] = styles[position - 1]
                    kept += 1
                    renumbered[position] = UInt32(kept)
                }
                styles.removeLast(styles.count - kept)
                for column in cells.indices { cells[column].style = renumbered[Int(cells[column].style)] }
            }
        }

        mutating func discardClusters(in range: Range<Int>) {
            if !clusters.isEmpty {
                clusters = clusters.filter { !range.contains($0.key) }
            }
        }

        private mutating func clearWideLead(before column: Int, style: UInt32) {
            if column > 0, stored(at: column - 1).width == 2 {
                cells[column - 1] = StoredCell(style: style)
                if !clusters.isEmpty { clusters.removeValue(forKey: column - 1) }
            }
        }

        private mutating func clearWideEdges(_ range: Range<Int>, style: UInt32) {
            guard !range.isEmpty else { return }
            clearWideLead(before: range.lowerBound, style: style)
            let end = range.upperBound
            if end < cells.count, cells[end].glyph == StoredCell.continuation {
                cells[end] = StoredCell(style: style)
            }
        }

        mutating func writeASCII(_ bytes: Span<UInt8>, at column: Int, style: Style) {
            let style = position(of: style)
            let end = column + bytes.count
            let range = column..<end
            clearWideEdges(range, style: style)
            discardClusters(in: range)
            if end > cells.count { reserveWidth() }
            ensureLength(column)
            // Text past the stored cells is appended rather than filled with blanks and then overwritten.
            let overwritten = min(end, cells.count) - column
            if overwritten > 0 {
                var target = cells.mutableSpan
                for offset in 0..<overwritten {
                    target[column + offset] = StoredCell(glyph: UInt32(bytes[offset]), style: style)
                }
            }
            if overwritten < bytes.count {
                cells.append(addingCapacity: bytes.count - overwritten) { appended in
                    for offset in overwritten..<bytes.count {
                        appended.append(StoredCell(glyph: UInt32(bytes[offset]), style: style))
                    }
                }
            }
        }

        mutating func write(_ scalar: Unicode.Scalar, at column: Int, width: Int, style: Style) {
            let style = position(of: style)
            let end = column + max(1, width)
            clearWideEdges(column..<end, style: style)
            discardClusters(in: column..<end)
            ensureLength(end)
            let flag: UInt32 = width == 2 ? StoredCell.wide : (width == 0 ? StoredCell.zeroWidth : 0)
            cells[column] = StoredCell(glyph: scalar.value | flag, style: style)
            if width == 2 { cells[column + 1] = StoredCell(glyph: StoredCell.continuation, style: style) }
        }

        /// Append complete, non-combining scalars that fit at the stored end of this row.
        mutating func appendRun(_ pending: inout SizedScalar?, limit: Int, style: Style,
                                next: () -> SizedScalar?) -> UInt64 {
            let style = position(of: style)
            var written: UInt64 = 0
            clearWideLead(before: cells.count, style: style)
            if cells.isEmpty { reserveWidth() }
            while let glyph = pending, glyph.width > 0, cells.count + glyph.width <= limit {
                let flag: UInt32 = glyph.width == 2 ? StoredCell.wide : 0
                cells.append(StoredCell(glyph: glyph.scalar.value | flag, style: style))
                if glyph.width == 2 { cells.append(StoredCell(glyph: StoredCell.continuation, style: style)) }
                written &+= 1
                pending = next()
            }
            return written
        }

        mutating func appendCombining(_ scalar: Unicode.Scalar, before column: Int) {
            let previous = column - 1
            let base = stored(at: previous).glyph == StoredCell.continuation ? max(0, previous - 1) : previous
            ensureLength(base + 1)
            if cells[base].scalar == 0 {
                cells[base].glyph = scalar.value
            } else {
                if clusters[base] == nil { clusters[base] = String(Unicode.Scalar(cells[base].scalar)!) }
                clusters[base]!.unicodeScalars.append(scalar)
            }
        }

        mutating func erase(_ range: Range<Int>, style: Style) {
            guard !range.isEmpty else { return }
            let style = position(of: style)
            clearWideLead(before: range.lowerBound, style: style)
            let end = range.upperBound
            if end < storageColumns, stored(at: end - 1).width == 2 {
                fillWithBlanks(end..<(end + 1), style: style)
            }
            fillWithBlanks(range, style: style)
        }

        /// Blanks cells without repairing a wide glyph that the range splits. `style` is a position
        /// from `position(of:)`, and zero is the default style.
        mutating func fillWithBlanks(_ range: Range<Int>, style: UInt32 = 0) {
            discardClusters(in: range)
            if style == 0, range.upperBound >= cells.count {
                // Unstored tail cells already have the default style.
                if range.lowerBound < cells.count { cells.removeLast(cells.count - range.lowerBound) }
                return
            }
            ensureLength(range.upperBound)
            let blank = StoredCell(style: style)
            for column in range { cells[column] = blank }
        }

        /// Gives the wide glyph before `column` its second half, in the default style.
        mutating func restoreContinuation(at column: Int) {
            ensureLength(column + 1)
            cells[column] = StoredCell(glyph: StoredCell.continuation)
        }

        mutating func editCharacters(_ edit: CharacterEdit, at start: Int, count requested: Int, style: Style) {
            // Editing shifts the entire stored row, including cells hidden by a narrower alternate viewport.
            let count = min(requested, storageColumns - start)
            let style = position(of: style)
            clearWideLead(before: start, style: style)
            switch edit {
            case .insert:
                move(start..<(storageColumns - count), to: start + count)
                fillWithBlanks(start..<(start + count), style: style)
                if stored(at: storageColumns - 1).width == 2 {
                    fillWithBlanks((storageColumns - 1)..<storageColumns, style: style)
                }
            case .delete:
                move((start + count)..<storageColumns, to: start)
                fillWithBlanks((storageColumns - count)..<storageColumns, style: style)
                // An orphaned continuation is empty. A standalone combining mark also has width zero.
                if stored(at: start).glyph == StoredCell.continuation {
                    fillWithBlanks(start..<(start + 1), style: style)
                }
            }
        }

        /// Moves cells and their clusters along this row. The cells keep their style positions.
        private mutating func move(_ range: Range<Int>, to start: Int) {
            guard !range.isEmpty else { return }
            ensureLength(max(range.upperBound, start + range.count))
            cells.withUnsafeMutableBufferPointer { cells in
                // Like memmove, this copies back to front when the cells move right over themselves.
                (cells.baseAddress! + start).update(from: cells.baseAddress! + range.lowerBound, count: range.count)
            }
            guard !clusters.isEmpty else { return }
            let moved = clusters.filter { range.contains($0.key) }
            discardClusters(in: start..<(start + range.count))
            for (index, text) in moved { clusters[start + index - range.lowerBound] = text }
        }

        /// Copies cells and their clusters from another row as reflow rewraps a line.
        /// Their styles join this row's list.
        mutating func copy(_ range: Range<Int>, from source: Self, to start: Int) {
            guard !range.isEmpty else { return }
            ensureLength(start + range.count)
            for offset in 0..<range.count {
                var cell = source.stored(at: range.lowerBound + offset)
                cell.style = position(of: source.style(of: cell))
                cells[start + offset] = cell
            }
            discardClusters(in: start..<(start + range.count))
            for (index, text) in source.clusters where range.contains(index) {
                clusters[start + index - range.lowerBound] = text
            }
        }

        mutating func truncate(to width: Int) {
            columns = width
            storageColumns = width
            if cells.count > width {
                cells.removeLast(cells.count - width)
                if !clusters.isEmpty { clusters = clusters.filter { $0.key < width } }
            }
        }
    }
}
