import Testing
@testable import ThrushCore
import ThrushFixtures

@Test func snapshotSharesUnchangedRowsAndKeepsItsCursor() throws {
    let fixture = try FirstBytesFixture.load()
    let prompt = try #require(fixture.events.first)
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    #expect(terminal.write(prompt.bytes) == prompt.reply)
    let previous = terminal.snapshot()

    for event in fixture.events.dropFirst() {
        // This single-pass sequence also exercises the carrier without contiguous storage.
        let bytes = sequence(state: event.bytes.makeIterator()) { $0.next() }
        #expect(terminal.write(bytes) == event.reply)
    }
    let latest = terminal.snapshot()
    #expect(latest.generation != previous.generation)
    #expect(previous.rows[0].text == prompt.text)
    #expect(previous.rows[1].text.isEmpty)
    #expect(previous.cursorRow == 0)
    #expect(previous.cursorColumn == prompt.text.utf8.count)
    #expect(latest.cursorRow == fixture.events.last?.row)
    #expect(latest.rows[0].generation == previous.rows[0].generation)
    #expect(latest.rows[1].generation != previous.rows[1].generation)
    let shared = previous.rows[0].cells.withUnsafeBufferPointer { old in
        latest.rows[0].cells.withUnsafeBufferPointer { new in old.baseAddress == new.baseAddress }
    }
    #expect(shared)
}

@Test func fullResetRedrawsEveryRowOnAFreshNormalScreen() {
    var terminal = Terminal(size: .init(columns: 4, rows: 2))
    _ = terminal.write("A\r\nB\r\nC\u{1b}[?1049h\u{1b}[?1000hALT".utf8)
    let before = terminal.snapshot()
    _ = terminal.write("\u{1b}c".utf8)
    let reset = terminal.snapshot()
    #expect(!reset.isAlternate)
    #expect(reset.history.isEmpty)
    #expect(reset.rows.map(\.text) == ["", ""])
    #expect(reset.modes.mouseTracking == .off)
    // A renderer that caches rows by generation must not reuse anything drawn before the reset.
    let drawn = before.rows.map(\.generation).max() ?? 0
    #expect(reset.rows.allSatisfy { $0.generation > drawn })
}

@Test func alternateResizeMaterializesAMissingRowAndErasePreservesHistory() {
    let size = Terminal.Size(columns: 2, rows: 3)
    var terminal = Terminal(size: size)
    terminal.resize(to: .init(columns: 2, rows: 2))
    _ = terminal.write("\u{1b}[?1049hA\r\nB\r\nC\u{1b}[H".utf8)
    let beforeGrow = terminal.snapshot()
    #expect(beforeGrow.history.map(\.text) == ["A"])
    #expect(beforeGrow.rows.map(\.text) == ["B", "C"])

    // Shrinking the alternate screen retains B above the viewport and exposes only two rows below it.
    // Its next physical slot aliases B. Thrush supplies an ordinary blank row there.
    terminal.resize(to: size)
    let grown = terminal.snapshot()
    #expect(grown.size == size)
    #expect(grown.isAlternate)
    #expect(grown.cursorRow == 0)
    #expect(grown.cursorColumn == 0)
    #expect(grown.history.map(\.text) == ["B"])
    #expect(grown.rows.map(\.text) == ["C", "", ""])
    #expect(grown.rows.allSatisfy { !$0.isWrapped })
    let missing = grown.rows[2]
    for column in 0..<size.columns {
        #expect(missing[column] == Terminal.Cell(text: "", width: 1, style: .init()))
    }

    _ = terminal.write("\u{1b}[2J".utf8)
    let erased = terminal.snapshot()
    #expect(erased.history.map(\.text) == ["B"])
    #expect(erased.rows.map(\.text) == ["", "", ""])
    #expect(erased.cursorRow == 0)
    #expect(erased.cursorColumn == 0)
    #expect(grown.rows[0].text == "C")
    #expect(beforeGrow.history.map(\.text) == ["A"])
    #expect(beforeGrow.rows.map(\.text) == ["B", "C"])
}

@Test func switchingPaletteReusesStyledCellsAndPreservesPreviousFrame() {
    var terminal = Terminal(size: .init(columns: 4, rows: 2))
    _ = terminal.write("A\u{1b}[31mB\u{1b}[38;2;12;34;56mC".utf8)
    let previous = terminal.snapshot()
    let original = previous.palette
    var ansi = original.ansi
    ansi.swapAt(0, 1)
    let custom = Terminal.Palette(foreground: original.background, background: original.foreground, ansi: ansi)
    terminal.palette = custom
    let changed = terminal.snapshot()
    #expect(changed.palette == custom)
    #expect(previous.palette == .default)
    #expect(previous.generation != changed.generation)
    #expect(previous.rows.map(\.generation) == changed.rows.map(\.generation))
    #expect(changed.rows[0][0].style.foreground == .default)
    #expect(changed.rows[0][1].style.foreground == .indexed(1))
    #expect(changed.rows[0][2].style.foreground == .rgb(12, 34, 56))
    let sharedCells = previous.rows[0].cells.withUnsafeBufferPointer { old in
        changed.rows[0].cells.withUnsafeBufferPointer { new in old.baseAddress == new.baseAddress }
    }
    #expect(sharedCells)
    terminal.palette = custom
    #expect(terminal.snapshot().generation == changed.generation)
}

@Test func recycledAndErasedRowsLeaveEarlierSnapshotsIntact() {
    var terminal = Terminal(size: .init(columns: 4, rows: 2))
    let limit = Terminal.History.limit
    // The oldest line ends in a combining mark, so its row carries a cluster in its second column.
    let lines = ["ae\u{301}"] + (1...(limit + 1)).map(String.init)
    _ = terminal.write(lines.joined(separator: "\r\n").utf8)
    let full = terminal.snapshot()

    // A line feed evicts the oldest history row and reuses it as the new bottom row.
    _ = terminal.write("\r\nX".utf8)
    let recycled = terminal.snapshot()
    #expect(recycled.history.first?.text == "1")
    #expect(recycled.rows.map(\.text) == ["\(limit + 1)", "X"])
    #expect(recycled.rows[1][1] == Terminal.Cell(text: "", width: 1, style: .init()))
    #expect(recycled.rows[1].generation != full.rows[1].generation)

    _ = terminal.write("\u{1b}[41m\u{1b}[2J".utf8)
    let erased = terminal.snapshot()
    #expect(erased.rows.map(\.text) == ["", ""])
    #expect(erased.rows.allSatisfy { row in (0..<4).allSatisfy { row[$0].style.background == .indexed(1) } })

    #expect(full.history.map(\.text) == Array(lines.prefix(limit)))
    #expect(full.rows.map(\.text) == ["\(limit)", "\(limit + 1)"])
    #expect(recycled.rows[1].text == "X")
}

@Test func scrollRegionsReuseRowsAndLeaveEarlierSnapshotsIntact() {
    var terminal = Terminal(size: .init(columns: 3, rows: 4))
    // Rows two through four scroll. The second row's combined glyph is a cluster that must not outlive its line.
    _ = terminal.write("top\r\ne\u{301}\r\nb\r\nc\u{1b}[2;4r".utf8)
    let full = terminal.snapshot()

    // A line feed at the bottom margin rotates the second row down to the bottom, cleared.
    _ = terminal.write("\u{1b}[4;1H\u{1b}[41m\n".utf8)
    let scrolled = terminal.snapshot()
    #expect(scrolled.rows.map(\.text) == ["top", "b", "c", ""])
    var red = Terminal.Style()
    red.background = .indexed(1)
    #expect((0..<3).allSatisfy { scrolled.rows[3][$0] == Terminal.Cell(text: "", width: 1, style: red) })
    #expect(scrolled.rows[1].generation == full.rows[2].generation)
    #expect(scrolled.rows[3].generation != full.rows[1].generation)

    // A reverse index at the top margin rotates the red bottom row up, cleared in the default style.
    _ = terminal.write("\u{1b}[2;1HM\u{1b}[2;1H\u{1b}[0m\u{1b}M".utf8)
    let reversed = terminal.snapshot()
    #expect(reversed.rows.map(\.text) == ["top", "", "M", "c"])
    #expect((0..<3).allSatisfy { reversed.rows[1][$0] == Terminal.Cell(text: "", width: 1, style: .init()) })

    #expect(full.rows.map(\.text) == ["top", "e\u{301}", "b", "c"])
    #expect(scrolled.rows.map(\.text) == ["top", "b", "c", ""])
}

@Test func scrollRegionsThatCrossTheEndOfTheRowRingKeepScreenOrder() {
    var terminal = Terminal(size: .init(columns: 3, rows: 5))
    // Three full-screen scrolls leave the second through fifth rows spanning the end of the row ring.
    _ = terminal.write("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\u{1b}[2;5r".utf8)
    let full = terminal.snapshot()

    _ = terminal.write("\u{1b}[3T".utf8)
    #expect(terminal.snapshot().rows.map(\.text) == ["d", "", "", "", "e"])
    _ = terminal.write("\u{1b}[5;1H\ni".utf8)
    #expect(terminal.snapshot().rows.map(\.text) == ["d", "", "", "e", "i"])
    _ = terminal.write("\u{1b}[2;1H\u{1b}[3M".utf8)
    #expect(terminal.snapshot().rows.map(\.text) == ["d", "i", "", "", ""])
    #expect(full.rows.map(\.text) == ["d", "e", "f", "g", "h"])
}

@Test func columnShiftsGiveEachRowItsOwnGeneration() {
    // A renderer caches each row's drawing by its generation, so rows with different cells need different ones.
    var terminal = Terminal(size: .init(columns: 6, rows: 3))
    _ = terminal.write("abc\r\ndef\u{1b}[H\u{1b}['}".utf8)
    let rows = terminal.snapshot().rows
    #expect(rows.map(\.text) == [" abc", " def", ""])
    #expect(rows[0].generation != rows[1].generation)
}

@Test func synchronizedOutputKeepsParsingAndAnswersQueriesBeforeRelease() throws {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    let start = "\u{1b}[?2026h", end = "\u{1b}[?2026l"
    let visible = terminal.snapshot()
    #expect(visible.synchronizedOutputID == nil)

    // The terminal advances the grid and returns CPR while synchronized output is active.
    #expect(terminal.write((start + "A\u{1b}[6n").utf8) == Array("\u{1b}[1;2R".utf8))
    let first = terminal.snapshot()
    let batch = try #require(first.synchronizedOutputID)
    _ = terminal.write("B".utf8)
    #expect(terminal.snapshot().synchronizedOutputID == batch)
    #expect(terminal.text(inRow: 0) == "AB")
    #expect(visible.rows[0].text.isEmpty)
    #expect(first.rows[0].text == "A")

    // A repeat begin is a new token for a presenter whose previous hold may already have timed out.
    _ = terminal.write((start + "C").utf8)
    let repeated = try #require(terminal.snapshot().synchronizedOutputID)
    #expect(repeated != batch)
    _ = terminal.write(end.utf8)
    let released = terminal.snapshot()
    #expect(released.synchronizedOutputID == nil)
    #expect(released.rows[0].text == "ABC")
}

@Test func rowsKeepEveryStyleWhileTheirStyleListsAreCompacted() {
    var terminal = Terminal(size: .init(columns: 4, rows: 2))
    func style(_ index: Int) -> Terminal.Style {
        var style = Terminal.Style()
        style.foreground = .rgb(UInt8(index), 255, 0)
        style.background = .indexed(UInt8(255 - index))
        style.bold = true
        style.strikethrough = index.isMultiple(of: 2)
        return style
    }
    func write(_ index: Int, at column: Int) {
        let strike = index.isMultiple(of: 2) ? 9 : 29
        _ = terminal.write("\u{1b}[1;\(column)H\u{1b}[1;\(strike);38;2;\(index);255;0;48;5;\(255 - index)mX".utf8)
    }
    // The last three columns take a new style on every write, so the row's list fills and is
    // compacted several times while the first column keeps one style from the middle of the list.
    for index in 0..<12 { write(index, at: index % 3 + 2) }
    write(99, at: 1)
    let earlier = terminal.snapshot()
    for index in 12..<40 { write(index, at: index % 3 + 2) }
    let row = terminal.snapshot().rows[0]
    #expect((0..<4).map { row[$0].style } == [99, 39, 37, 38].map(style))
    #expect((0..<4).map { earlier.rows[0][$0].style } == [99, 9, 10, 11].map(style))
}

@Test func reflowCarriesEachCellsStyleIntoItsNewRow() {
    var terminal = Terminal(size: .init(columns: 4, rows: 3))
    // The cursor moves below the line, so the line reflows rather than waiting for a repaint.
    _ = terminal.write(((1...5).map { "\u{1b}[3\($0)m\(Character(Unicode.Scalar(64 + $0)!))" }.joined() + "\r\n").utf8)
    func colors() -> [[Terminal.Color]] {
        let snapshot = terminal.snapshot()
        return (snapshot.history + snapshot.rows).map { row in
            (0..<row.columns).compactMap { row[$0].text.isEmpty ? nil : row[$0].style.foreground }
        }.filter { !$0.isEmpty }
    }
    terminal.resize(to: .init(columns: 8, rows: 3))
    #expect(colors() == [(1...5).map { .indexed(UInt8($0)) }])
    terminal.resize(to: .init(columns: 2, rows: 3))
    #expect(colors() == [[.indexed(1), .indexed(2)], [.indexed(3), .indexed(4)], [.indexed(5)]])
}

@Test func narrowingALongWrappedLineKeepsItsTailInHistory() {
    var terminal = Terminal(size: .init(columns: 48, rows: 2))
    let glyphs = (0..<2048).map { String(Unicode.Scalar(0x4e00 + $0)!) }
    _ = terminal.write((glyphs.joined() + "\r\n").utf8)
    terminal.resize(to: .init(columns: 2, rows: 2))

    // Each glyph fills one row. The last glyph and the following blank fill the viewport.
    let snapshot = terminal.snapshot()
    #expect(snapshot.rows.map(\.text) == [glyphs.last!, ""])
    #expect(snapshot.history.map(\.text) == Array(glyphs.dropLast().suffix(Terminal.History.limit)))
    #expect(snapshot.history.allSatisfy { $0.isWrapped && $0[0].width == 2 && $0[1].width == 0 })
}

@Test func extendedViewportHoldsTheRowsATallerGridBringsIntoView() {
    var terminal = Terminal(size: .init(columns: 8, rows: 3))
    _ = terminal.write("one\r\ntwo\r\nthree\r\nfour\r\n$ ".utf8)
    let held = terminal.snapshot()
    terminal.resize(to: .init(columns: 8, rows: 5))
    let taller = terminal.snapshot()

    // At the live edge, the rows above are the history the taller grid pulls back.
    let live = held.viewport(rowsFromBottom: 0, extendedBy: 2)
    #expect(live.rows.map(\.text) == ["one", "two", "three", "four", "$ ", "", ""])
    #expect(live.rows.prefix(5).map(\.text) == taller.rows.map(\.text))
    #expect(live.cursorRow == taller.cursorRow && live.size == held.size)

    // A reader keeps the top row, and the rows below it come into view.
    let reading = held.viewport(rowsFromBottom: 1, extendedBy: 1)
    #expect(reading.rows.map(\.text) == ["one", "two", "three", "four", "$ "])
    #expect(reading.cursorRow == 4 && reading.cursorVisible)
}

@Test func heldSnapshotKeepsRowsAndCursorAcrossEditsAndScroll() {
    var terminal = Terminal(size: .init(columns: 6, rows: 3))
    _ = terminal.write("first\r\nnext".utf8)
    let first = terminal.snapshot()
    let originalText = first.rows.map(\.text)
    let originalGenerations = first.rows.map(\.generation)
    let originalCursor = (first.cursorRow, first.cursorColumn)

    _ = terminal.write("\rNEW".utf8)
    let edited = terminal.snapshot()
    #expect(edited.generation > first.generation)
    #expect(edited.rows[0].generation == originalGenerations[0])
    #expect(edited.rows[1].generation != originalGenerations[1])
    #expect(edited.rows[2].generation == originalGenerations[2])

    // One contiguous write scrolls two rows into history and writes three distinct new rows.
    _ = terminal.write("\r\nABCDEFGHIJKLMNO".utf8)
    let scrolled = terminal.snapshot()
    #expect(scrolled.generation > edited.generation)
    #expect(scrolled.history.map(\.generation) == Array(edited.rows.prefix(2)).map(\.generation))
    #expect(Set(scrolled.rows.map(\.generation)).count == 3)
    #expect(first.rows.map(\.text) == originalText)
    #expect(first.rows.map(\.generation) == originalGenerations)
    #expect((first.cursorRow, first.cursorColumn) == originalCursor)
    #expect(first.history.isEmpty)
}
