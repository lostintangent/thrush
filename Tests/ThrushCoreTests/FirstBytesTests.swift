import Testing
import ThrushCore
import ThrushFixtures

@Test(arguments: [Int.max, 1, 2, 3, 7])
func firstBytesAtEachCheckpoint(chunkLimit: Int) throws {
    let fixture = try FirstBytesFixture.load()
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    for event in fixture.events {
        var pending = event.bytes[...]
        var reply: [UInt8] = []
        while !pending.isEmpty {
            let chunk = pending.prefix(chunkLimit)
            reply += terminal.receive(chunk)
            pending.removeFirst(chunk.count)
        }
        #expect(reply == event.reply, "\(event.name) reply")
        #expect(terminal.text(inRow: event.row) == event.text, "\(event.name) visible row")
        if let up = event.up {
            #expect(terminal.encode(.key(.up)) == up, "\(event.name) Up arrow")
        }
    }
}

@Test func entireTranscriptAndEverySingleSplit() throws {
    let fixture = try FirstBytesFixture.load()
    let transcript = fixture.events.flatMap(\.bytes)
    let expectedReplies = fixture.events.flatMap(\.reply)
    var expectedRows = Array(repeating: "", count: fixture.rows)
    for event in fixture.events {
        expectedRows[event.row] = event.text
    }

    for split in 0...transcript.count {
        var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
        var replies = terminal.receive(transcript[..<split])
        replies += terminal.receive(transcript[split...])
        #expect(replies == expectedReplies, "Reply order at split \(split)")
        let rows = (0..<fixture.rows).map { terminal.text(inRow: $0) }
        #expect(rows == expectedRows, "Screen at split \(split)")
    }
}
