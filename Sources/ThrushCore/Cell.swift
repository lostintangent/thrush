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

    /// How text is underlined. SGR 4 with a colon subparameter selects each one.
    package enum Underline: UInt8, Sendable {
        case none, single, double, curly, dotted, dashed
    }

    /// A style packs both colors and the rendition flags into one integer, and the underline color and
    /// link into a second, so the default style is zero and comparing two styles is a pair of compares.
    package struct Style: Equatable, Sendable {
        // The foreground in the low 26 bits, the background in the next 26, eight flags above them
        // and then the underline in three bits.
        private var bits: UInt64 = 0
        // The underline color in the low 26 bits and the link's number in the high 32.
        private var decoration: UInt64 = 0
        private static let color: UInt64 = 1 << 26 - 1
        private static let background = 26
        private static let flags = 52
        private static let underline = 60
        private static let link = 32

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
        package var blink: Bool { get { self[8] } set { self[8] = newValue } }
        package var inverse: Bool { get { self[16] } set { self[16] = newValue } }
        package var invisible: Bool { get { self[32] } set { self[32] = newValue } }
        package var strikethrough: Bool { get { self[64] } set { self[64] = newValue } }
        package var overline: Bool { get { self[128] } set { self[128] = newValue } }

        package var underline: Underline {
            get { Underline(rawValue: UInt8(truncatingIfNeeded: bits >> Self.underline & 7)) ?? .none }
            set { bits = bits & ~(7 << Self.underline) | UInt64(newValue.rawValue) << Self.underline }
        }

        /// The default draws the underline in the text's own color.
        package var underlineColor: Color {
            get { Color(bits: UInt32(truncatingIfNeeded: decoration & Self.color)) }
            set { decoration = decoration & ~Self.color | UInt64(newValue.bits) }
        }

        /// The number of the text's link in the screen's link table, or zero without one.
        package var link: UInt32 {
            get { UInt32(truncatingIfNeeded: decoration >> Self.link) }
            set { decoration = decoration & Self.color | UInt64(newValue) << Self.link }
        }

        var isDefault: Bool { bits | decoration == 0 }

        /// SGR 0 returns every rendition to its default. The link is not a rendition, so it stays.
        mutating func resetRenditions() {
            bits = 0
            decoration &= ~Self.color
        }

        /// Erased cells use the current background color with default rendition and no link.
        var eraseStyle: Self {
            var result = Self()
            result.bits = bits & Self.color << Self.background
            return result
        }

        /// DECALN's test pattern keeps the colors and flags, but is neither underlined nor a link.
        var alignmentStyle: Self {
            var result = Self()
            result.bits = bits & ~(7 << Self.underline)
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
        var stylePosition: UInt32 = 0

        /// A scalar with the flag for its width.
        static func glyph(_ scalar: Unicode.Scalar, width: Int) -> UInt32 {
            scalar.value | (width == 2 ? wide : (width == 0 ? zeroWidth : 0))
        }

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
        // The cells written so far, with room for every column so writing never reallocates. Only
        // the cells before `length` are in use, and the columns from there on are blank in the
        // default style. Clearing a row just resets `length`. ASCII written past the stored cells is
        // appended, and a run of other text first stores blanks through the row's last column.
        var cells: [StoredCell]
        private(set) var length = 0
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
            // A snapshot that still shares the cells, styles or clusters keeps them. This row copies
            // the cells when it next writes, and its styles and clusters start over in new storage.
            length = 0
            if !styles.isEmpty { styles.removeAll(keepingCapacity: true) }
            if !clusters.isEmpty { emptyClusters() }
            fill(with: style)
        }

        // Out of line, so clearing a row without clusters stays small.
        @inline(never)
        private mutating func emptyClusters() {
            clusters.removeAll(keepingCapacity: true)
        }

        // Default blanks stay implied. A blank row in any other style stores every column.
        @inline(__always)
        private mutating func fill(with style: Style) {
            if !style.isDefault { fillColumns(with: style) }
        }

        @inline(never)
        private mutating func fillColumns(with style: Style) {
            styles.append(style)
            prepareToWrite(0..<columns)
            set(0..<columns, to: StoredCell(stylePosition: 1))
        }

        func stored(at column: Int) -> StoredCell {
            column < length ? cells[column] : StoredCell()
        }

        /// Adds the links of the styles this row holds, including any no cell uses anymore.
        func insertLinks(into links: inout Links.NumberSet) {
            for style in styles where style.link != 0 { links.insert(style.link) }
        }

        func style(of cell: StoredCell) -> Style {
            cell.stylePosition == 0 ? Style() : styles[Int(cell.stylePosition) - 1]
        }

        package subscript(column: Int) -> Cell {
            precondition((0..<columns).contains(column))
            let cell = stored(at: column)
            let text = cell.scalar == 0 ? "" : clusters[column] ?? String(Unicode.Scalar(cell.scalar)!)
            return Cell(text: text, width: cell.width, style: style(of: cell))
        }

        // A printed space or an erased cell with a background belongs to the transcript.
        var hasContent: Bool { cells.prefix(min(columns, length)).contains { $0.glyph != 0 || $0.stylePosition != 0 } }

        package var trimmedLength: Int {
            var end = length
            while end > 0 {
                let cell = cells[end - 1]
                if cell.scalar != 0 { return min(columns, end - 1 + cell.width) }
                end -= 1
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

        /// Puts the cells in `range` in use for the caller to write every one of them. Unused cells
        /// before the range become blanks in the default style.
        private mutating func prepareToWrite(_ range: Range<Int>) {
            extend(to: range.lowerBound)
            store(upTo: range.upperBound)
            length = max(length, range.upperBound)
        }

        /// Puts the cells before `end` in use, as blanks in the default style where they weren't.
        private mutating func extend(to end: Int) {
            if end > length { blankUnusedCells(before: end) }
        }

        /// Stores cells before `end`, as blanks where there were none.
        private mutating func store(upTo end: Int) {
            let missing = end - cells.count
            if missing > 0 { appendCells(upTo: end) { $0.append(repeating: StoredCell(), count: missing) } }
        }

        /// Appends the cells `body` writes, up to `end`, keeping room for every column.
        private mutating func appendCells(upTo end: Int, _ body: (inout OutputSpan<StoredCell>) -> Void) {
            cells.append(addingCapacity: max(storageColumns, end) - cells.count, initializingWith: body)
        }

        // Out of line, so the checks above inline into every write.
        @inline(never)
        private mutating func blankUnusedCells(before end: Int) {
            store(upTo: end)
            set(length..<end, to: StoredCell())
            length = end
        }

        private mutating func set(_ range: Range<Int>, to cell: StoredCell) {
            var target = cells.mutableSpan
            for column in range { target[column] = cell }
        }

        /// Returns the position a cell stores for `style`. Text changes style far less often than
        /// it prints a cell, so the default style and the last one added cover nearly every lookup.
        /// Any other style is appended, even if an older entry matches.
        @inline(__always)
        private mutating func position(of style: Style) -> UInt32 {
            style.isDefault ? 0 : listedPosition(of: style)
        }

        // Out of line, so default text pays only the check above.
        @inline(never)
        private mutating func listedPosition(of style: Style) -> UInt32 {
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
            withTemporaryAllocation(of: UInt32.self, capacity: styles.count + 1) { renumbered in
                renumbered.append(repeating: 0, count: styles.count + 1)
                for cell in cells[..<length] { renumbered[Int(cell.stylePosition)] = 1 }
                renumbered[0] = 0
                var kept = 0
                for position in 1..<renumbered.count where renumbered[position] != 0 {
                    styles[kept] = styles[position - 1]
                    kept += 1
                    renumbered[position] = UInt32(kept)
                }
                styles.removeLast(styles.count - kept)
                for column in 0..<length { cells[column].stylePosition = renumbered[Int(cells[column].stylePosition)] }
            }
        }

        mutating func discardClusters(in range: Range<Int>) {
            if !clusters.isEmpty {
                clusters = clusters.filter { !range.contains($0.key) }
            }
        }

        private mutating func clearWideLead(before column: Int, style: UInt32) {
            if column > 0, stored(at: column - 1).width == 2 {
                cells[column - 1] = StoredCell(stylePosition: style)
                if !clusters.isEmpty { clusters.removeValue(forKey: column - 1) }
            }
        }

        private mutating func clearWideEdges(_ range: Range<Int>, style: UInt32) {
            guard !range.isEmpty else { return }
            clearWideLead(before: range.lowerBound, style: style)
            let end = range.upperBound
            if end < length, cells[end].glyph == StoredCell.continuation {
                cells[end] = StoredCell(stylePosition: style)
            }
        }

        mutating func writeASCII(_ bytes: Span<UInt8>, at column: Int, style: Style) {
            let style = position(of: style)
            let end = column + bytes.count
            let range = column..<end
            clearWideEdges(range, style: style)
            discardClusters(in: range)
            extend(to: column)
            if column == cells.count {
                appendCells(upTo: end) { appended in
                    for offset in 0..<bytes.count {
                        appended.append(StoredCell(glyph: UInt32(bytes[offset]), stylePosition: style))
                    }
                }
            } else {
                store(upTo: end)
                var target = cells.mutableSpan
                for offset in 0..<bytes.count {
                    target[column &+ offset] = StoredCell(glyph: UInt32(bytes[offset]), stylePosition: style)
                }
            }
            length = max(length, end)
        }

        mutating func write(_ scalar: Unicode.Scalar, at column: Int, width: Int, style: Style) {
            let style = position(of: style)
            let end = column + max(1, width)
            clearWideEdges(column..<end, style: style)
            discardClusters(in: column..<end)
            prepareToWrite(column..<end)
            cells[column] = StoredCell(glyph: StoredCell.glyph(scalar, width: width), stylePosition: style)
            if width == 2 { cells[column + 1] = StoredCell(glyph: StoredCell.continuation, stylePosition: style) }
        }

        /// Appends glyphs from `next`, at or past the cells in use, until one is zero width or
        /// doesn't fit before `limit`. Returns how many it wrote.
        mutating func appendRun(_ glyphs: Span<UInt32>, from next: inout Int, at column: Int, limit: Int,
                                style: Style) -> UInt64 {
            let style = position(of: style)
            clearWideLead(before: column, style: style)
            extend(to: column)
            store(upTo: limit)
            var target = cells.mutableSpan
            let first = next
            var end = column
            while next < glyphs.count {
                let glyph = glyphs[next]
                let width = 1 &+ Int(glyph >> 21 & 1)
                guard glyph & StoredCell.zeroWidth == 0, end &+ width <= limit else { break }
                // Every glyph writes a continuation after it, so the loop doesn't branch on width.
                // A narrow glyph's lands where the next glyph goes, or past the cells in use.
                target[min(end &+ 1, limit &- 1)] = StoredCell(glyph: StoredCell.continuation, stylePosition: style)
                target[end] = StoredCell(glyph: glyph, stylePosition: style)
                end &+= width
                next &+= 1
            }
            length = end
            return UInt64(next - first)
        }

        mutating func appendCombining(_ scalar: Unicode.Scalar, before column: Int) {
            let previous = column - 1
            let base = stored(at: previous).glyph == StoredCell.continuation ? max(0, previous - 1) : previous
            extend(to: base + 1)
            if cells[base].scalar == 0 {
                cells[base].glyph = scalar.value
            } else {
                let first = cells[base].scalar
                clusters[base, default: String(Unicode.Scalar(first)!)].unicodeScalars.append(scalar)
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
            if style == 0, range.upperBound >= length {
                // Columns past the cells in use are default blanks already.
                length = min(length, range.lowerBound)
                return
            }
            prepareToWrite(range)
            set(range, to: StoredCell(stylePosition: style))
        }

        /// Gives the wide glyph before `column` its second half, in the default style.
        mutating func restoreContinuation(at column: Int) {
            prepareToWrite(column..<(column + 1))
            cells[column] = StoredCell(glyph: StoredCell.continuation)
        }

        mutating func editCharacters(_ edit: CharacterEdit, at start: Int, count requested: Int, style: Style) {
            // Editing shifts the entire stored row, including cells hidden by a narrower alternate viewport.
            let count = min(requested, storageColumns - start)
            let style = position(of: style)
            clearWideLead(before: start, style: style)
            switch edit {
            case .insert:
                // The cells pushed past the row's end come around to the start of the edit and are blanked there.
                rotate(start..<storageColumns, by: count)
                fillWithBlanks(start..<(start + count), style: style)
                if stored(at: storageColumns - 1).width == 2 {
                    fillWithBlanks((storageColumns - 1)..<storageColumns, style: style)
                }
            case .delete:
                // The deleted cells come around to the row's end and are blanked there.
                rotate(start..<storageColumns, by: -count)
                fillWithBlanks((storageColumns - count)..<storageColumns, style: style)
                // An orphaned continuation is empty. A standalone combining mark also has width zero.
                if stored(at: start).glyph == StoredCell.continuation {
                    fillWithBlanks(start..<(start + 1), style: style)
                }
            }
        }

        /// Rotates the cells in `range` and their clusters toward the row's end by `offset`, or toward
        /// its start when it's negative. The cells keep their style positions.
        private mutating func rotate(_ range: Range<Int>, by offset: Int) {
            extend(to: range.upperBound)
            cells.rotate(range, by: offset)
            guard !clusters.isEmpty else { return }
            let count = range.count
            clusters = Dictionary(uniqueKeysWithValues: clusters.map { column, text in
                guard range.contains(column) else { return (column, text) }
                return (range.lowerBound + (column - range.lowerBound + offset % count + count) % count, text)
            })
        }

        /// Copies cells and their clusters from another row as reflow rewraps a line.
        /// Their styles join this row's list.
        mutating func copy(_ range: Range<Int>, from source: Self, to start: Int) {
            guard !range.isEmpty else { return }
            prepareToWrite(start..<(start + range.count))
            for offset in 0..<range.count {
                var cell = source.stored(at: range.lowerBound + offset)
                cell.stylePosition = position(of: source.style(of: cell))
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
            length = min(length, width)
            if cells.count > width {
                cells.removeLast(cells.count - width)
                if !clusters.isEmpty { clusters = clusters.filter { $0.key < width } }
            }
        }
    }
}
