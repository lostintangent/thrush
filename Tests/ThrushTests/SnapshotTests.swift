import Testing
@testable import Thrush
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

    // xterm 6.0.0 retains B above the viewport and exposes only two rows below it.
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
