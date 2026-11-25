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
