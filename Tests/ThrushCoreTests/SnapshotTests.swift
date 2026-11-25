import Testing
@testable import ThrushCore
import ThrushFixtures

@Test func snapshotSharesUnchangedRowsAndKeepsItsCursor() throws {
    let fixture = try FirstBytesFixture.load()
    let prompt = try #require(fixture.events.first)
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    #expect(terminal.receive(prompt.bytes) == prompt.reply)
    let previous = terminal.snapshot()

    for event in fixture.events.dropFirst() {
        // This single-pass sequence also exercises the carrier without contiguous storage.
        let bytes = sequence(state: event.bytes.makeIterator()) { $0.next() }
        #expect(terminal.receive(bytes) == event.reply)
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

@Test func alternateResizeMaterializesAMissingRowAndErasePreservesHistory() {
    let size = Terminal.Size(columns: 2, rows: 3)
    var terminal = Terminal(size: size)
    terminal.resize(to: .init(columns: 2, rows: 2))
    _ = terminal.receive("\u{1b}[?1049hA\r\nB\r\nC\u{1b}[H".utf8)
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

    _ = terminal.receive("\u{1b}[2J".utf8)
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
    _ = terminal.receive("A\u{1b}[31mB\u{1b}[38;2;12;34;56mC".utf8)
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

@Test func synchronizedOutputKeepsParsingAndAnswersQueriesBeforeRelease() throws {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    let start = "\u{1b}[?2026h", end = "\u{1b}[?2026l"
    let visible = terminal.snapshot()
    #expect(visible.synchronizedOutputID == nil)

    // The terminal advances the grid and returns CPR while synchronized output is active.
    #expect(terminal.receive((start + "A\u{1b}[6n").utf8) == Array("\u{1b}[1;2R".utf8))
    let first = terminal.snapshot()
    let batch = try #require(first.synchronizedOutputID)
    _ = terminal.receive("B".utf8)
    #expect(terminal.snapshot().synchronizedOutputID == batch)
    #expect(terminal.text(inRow: 0) == "AB")
    #expect(visible.rows[0].text.isEmpty)
    #expect(first.rows[0].text == "A")

    // A repeat begin is a new token for a presenter whose previous hold may already have timed out.
    _ = terminal.receive((start + "C").utf8)
    let repeated = try #require(terminal.snapshot().synchronizedOutputID)
    #expect(repeated != batch)
    _ = terminal.receive(end.utf8)
    let released = terminal.snapshot()
    #expect(released.synchronizedOutputID == nil)
    #expect(released.rows[0].text == "ABC")
}
