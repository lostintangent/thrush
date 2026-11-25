// A row stores each glyph’s column width and style alongside its text. Single scalars
// stay in the cell. Only glyphs with combining marks need a separate string.

extension Terminal {
    enum CharacterEdit { case insert, delete }

    package enum Color: Equatable, Sendable {
        case `default`, indexed(UInt8), rgb(UInt8, UInt8, UInt8)
    }

    package struct Style: Equatable, Sendable {
        package var foreground: Color = .default
        package var background: Color = .default
        private var flags: UInt8 = 0

        package init() {}

        private subscript(bit: UInt8) -> Bool {
            get { flags & bit != 0 }
            set { if newValue { flags |= bit } else { flags &= ~bit } }
        }

        package var bold: Bool { get { self[1] } set { self[1] = newValue } }
        package var dim: Bool { get { self[2] } set { self[2] = newValue } }
        package var italic: Bool { get { self[4] } set { self[4] = newValue } }
        package var underline: Bool { get { self[8] } set { self[8] = newValue } }
        package var blink: Bool { get { self[16] } set { self[16] = newValue } }
        package var inverse: Bool { get { self[32] } set { self[32] = newValue } }
        package var invisible: Bool { get { self[64] } set { self[64] = newValue } }
        package var strikethrough: Bool { get { self[128] } set { self[128] = newValue } }

        /// Erased cells use the current background color with default rendition.
        var eraseStyle: Self {
            var result = Self()
            result.background = background
            return result
        }
    }

    package struct Cell: Equatable, Sendable {
        package let text: String
        package let width: Int
        package let style: Style
    }

    /// The common case occupies one scalar and its attributes. Only combined glyphs need a String.
    struct StoredCell: Sendable {
        static let wide: UInt32 = 1 << 21
        static let continuation: UInt32 = 1 << 22
        static let zeroWidth: UInt32 = 1 << 23
        var glyph: UInt32 = 0
        var style = Style()

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
        var clusters: [Int: String] = [:]

        init(columns: Int, generation: UInt64, style: Style = .init(), wrapped: Bool = false) {
            self.columns = columns
            storageColumns = columns
            self.generation = generation
            self.isWrapped = wrapped
            cells = style == Style() ? [] : Array(repeating: StoredCell(style: style), count: columns)
        }

        /// Makes this row equal to `Row(columns:generation:style:wrapped:)` but keeps its cell storage,
        /// so a recycled row takes its next line without allocating.
        mutating func clear(columns: Int, generation: UInt64, style: Style = .init(), wrapped: Bool = false) {
            self.columns = columns
            storageColumns = columns
            self.generation = generation
            isWrapped = wrapped
            // A snapshot that still shares the cells keeps them, and this row gets new storage.
            cells.removeAll(keepingCapacity: true)
            if style != Style() { cells.append(contentsOf: repeatElement(StoredCell(style: style), count: columns)) }
            if !clusters.isEmpty { clusters.removeAll() }
        }

        func stored(at column: Int) -> StoredCell {
            column < cells.count ? cells[column] : StoredCell()
        }

        package subscript(column: Int) -> Cell {
            precondition((0..<columns).contains(column))
            let cell = stored(at: column)
            let text = clusters[column] ?? (cell.scalar == 0 ? "" : String(Unicode.Scalar(cell.scalar)!))
            return Cell(text: text, width: cell.width, style: cell.style)
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
            cells.append(contentsOf: repeatElement(StoredCell(), count: length - cells.count))
        }

        // Also gives a row shared with a snapshot its own full-width copy before it grows.
        private mutating func reserveWidth() {
            cells.reserveCapacity(storageColumns)
        }

        mutating func discardClusters(in range: Range<Int>) {
            if !clusters.isEmpty {
                clusters = clusters.filter { !range.contains($0.key) }
            }
        }

        private mutating func clearWideLead(before column: Int, style: Style) {
            if column > 0, stored(at: column - 1).width == 2 {
                cells[column - 1] = StoredCell(style: style)
                if !clusters.isEmpty { clusters.removeValue(forKey: column - 1) }
            }
        }

        mutating func clearWideEdges(_ range: Range<Int>, style: Style) {
            guard !range.isEmpty else { return }
            clearWideLead(before: range.lowerBound, style: style)
            let end = range.upperBound
            if end < cells.count, cells[end].glyph == StoredCell.continuation {
                cells[end] = StoredCell(style: style)
            }
        }

        mutating func writeASCII(_ bytes: Span<UInt8>, at column: Int, style: Style) {
            let end = column + bytes.count
            let range = column..<end
            clearWideEdges(range, style: style)
            discardClusters(in: range)
            if end > cells.count { reserveWidth() }
            ensureLength(column)
            // Text past the stored cells is appended rather than filled with blanks and then overwritten.
            let overwritten = min(end, cells.count) - column
            do {
                var target = cells.mutableSpan
                for offset in 0..<overwritten {
                    target[column + offset] = StoredCell(glyph: UInt32(bytes[offset]), style: style)
                }
            }
            for offset in overwritten..<bytes.count {
                cells.append(StoredCell(glyph: UInt32(bytes[offset]), style: style))
            }
        }

        mutating func write(_ scalar: Unicode.Scalar, at column: Int, width: Int, style: Style) {
            let end = column + max(1, width)
            clearWideEdges(column..<end, style: style)
            discardClusters(in: column..<end)
            ensureLength(end)
            let flag: UInt32 = width == 2 ? StoredCell.wide : (width == 0 ? StoredCell.zeroWidth : 0)
            cells[column] = StoredCell(glyph: scalar.value | flag, style: style)
            if width == 2 { cells[column + 1] = StoredCell(glyph: StoredCell.continuation, style: style) }
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
            clearWideLead(before: range.lowerBound, style: style)
            let end = range.upperBound
            if end < storageColumns, stored(at: end - 1).width == 2 {
                fillWithBlanks(end..<(end + 1), style: style)
            }
            fillWithBlanks(range, style: style)
        }

        private mutating func fillWithBlanks(_ range: Range<Int>, style: Style) {
            discardClusters(in: range)
            if style == Style(), range.upperBound >= cells.count {
                // Unstored tail cells already have the default style.
                if range.lowerBound < cells.count { cells.removeLast(cells.count - range.lowerBound) }
                return
            }
            ensureLength(range.upperBound)
            let blank = StoredCell(style: style)
            for column in range { cells[column] = blank }
        }

        mutating func editCharacters(_ edit: CharacterEdit, at start: Int, count requested: Int, style: Style) {
            // Editing shifts the entire stored row, including cells hidden by a narrower alternate viewport.
            let count = min(requested, storageColumns - start)
            clearWideLead(before: start, style: style)
            switch edit {
            case .insert:
                copy(start..<(storageColumns - count), from: self, to: start + count)
                fillWithBlanks(start..<(start + count), style: style)
                if stored(at: storageColumns - 1).width == 2 {
                    fillWithBlanks((storageColumns - 1)..<storageColumns, style: style)
                }
            case .delete:
                copy((start + count)..<storageColumns, from: self, to: start)
                fillWithBlanks((storageColumns - count)..<storageColumns, style: style)
                // An orphaned continuation is empty. A standalone combining mark also has width zero.
                if stored(at: start).glyph == StoredCell.continuation {
                    fillWithBlanks(start..<(start + 1), style: style)
                }
            }
        }

        /// Used when cells move horizontally or across reflow boundaries. Copy all attributes and clusters.
        mutating func copy(_ range: Range<Int>, from source: Self, to start: Int) {
            guard !range.isEmpty else { return }
            ensureLength(start + range.count)
            let limit = min(range.upperBound, source.cells.count)
            if limit > range.lowerBound {
                cells.replaceSubrange(start..<(start + limit - range.lowerBound), with: source.cells[range.lowerBound..<limit])
            }
            if limit < range.upperBound {
                let blankStart = start + max(0, limit - range.lowerBound)
                for column in blankStart..<(start + range.count) { cells[column] = StoredCell() }
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
