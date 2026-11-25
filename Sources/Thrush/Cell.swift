extension Terminal {
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
        var cells: [StoredCell]
        var clusters: [Int: String] = [:]

        init(columns: Int, generation: UInt64, style: Style = .init(), wrapped: Bool = false) {
            self.columns = columns
            storageColumns = columns
            self.generation = generation
            self.isWrapped = wrapped
            cells = style == Style() ? [] : Array(repeating: StoredCell(style: style), count: columns)
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

        var trimmedLength: Int {
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
            if cells.count < length {
                cells.append(contentsOf: repeatElement(StoredCell(), count: length - cells.count))
            }
        }

        mutating func discardClusters(in range: Range<Int>) {
            if !clusters.isEmpty {
                clusters = clusters.filter { !range.contains($0.key) }
            }
        }

        /// An edit touching half of a wide glyph invalidates the other half as well.
        mutating func clearWideEdges(_ range: Range<Int>, style: Style) {
            guard !range.isEmpty else { return }
            let start = range.lowerBound
            let end = range.upperBound
            if start > 0, stored(at: start - 1).width == 2 {
                cells[start - 1] = StoredCell(style: style)
                if !clusters.isEmpty { clusters.removeValue(forKey: start - 1) }
            }
            if end < cells.count, cells[end].glyph == StoredCell.continuation {
                cells[end] = StoredCell(style: style)
            }
        }

        mutating func writeASCII(_ bytes: UnsafeBufferPointer<UInt8>, at column: Int, style: Style) {
            let end = column + bytes.count
            let range = column..<end
            clearWideEdges(range, style: style)
            discardClusters(in: range)
            ensureLength(end)
            cells.withUnsafeMutableBufferPointer { target in
                for offset in bytes.indices {
                    target[column + offset] = StoredCell(glyph: UInt32(bytes[offset]), style: style)
                }
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
            clearWideEdges(range, style: style)
            discardClusters(in: range)
            if style != Style() { ensureLength(range.upperBound) }
            let end = min(cells.count, range.upperBound)
            if range.lowerBound < end {
                for column in range.lowerBound..<end { cells[column] = StoredCell(style: style) }
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
