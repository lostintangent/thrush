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

@Test func cursorAndTitleControlsCanCrossContiguousAndSinglePassInput() {
    func singlePass(_ bytes: [UInt8]) -> some Sequence<UInt8> {
        sequence(state: bytes.makeIterator()) { $0.next() }
    }
    var terminal = Terminal(size: .init(columns: 12, rows: 3))

    // The next ASCII digit ends an invalid UTF-8 prefix and still belongs to this CSI.
    _ = terminal.receive("\u{1B}[2;".utf8)
    _ = terminal.receive(singlePass([0xe2, 0x82]))
    _ = terminal.receive("4HX".utf8)
    _ = terminal.receive(singlePass([0x9b])) // Raw C1 is an invalid standalone UTF-8 byte.
    _ = terminal.receive("ab".utf8)
    _ = terminal.receive(singlePass([0xc2]))
    let cursorQueryTail: [UInt8] = [0x9b, 0x36, 0x6e]
    #expect(terminal.receive(cursorQueryTail) == Array("\u{1B}[2;7R".utf8))
    #expect(terminal.text(inRow: 1) == "   Xab")

    _ = terminal.receive("\u{1B}]2;old\u{07}\u{1B}]2;new".utf8)
    _ = terminal.receive(singlePass([0xc2]))
    #expect(terminal.title == "old")
    let encodedSTSuffix: [UInt8] = [0x9c]
    _ = terminal.receive(encodedSTSuffix)
    #expect(terminal.title == "new")
}

@Test func carriageReturnInterruptsUTF8AndIsIgnoredInsideATitle() {
    // The interrupted bytes would spell 界 if CR left the UTF-8 decoder pending.
    let interrupted: [UInt8] = [0xe7, 0x0d, 0x95, 0x8c]
    let bytes = Array("AB".utf8) + interrupted + Array("X\u{1b}]2;left\r\nright\u{7}Y\u{1b}[6n".utf8)

    for split in 0...bytes.count {
        var terminal = Terminal(size: .init(columns: 9, rows: 3))
        let prefix = sequence(state: bytes[..<split].makeIterator()) { $0.next() }
        var reply = terminal.receive(prefix)
        reply += terminal.receive(bytes[split...])

        #expect(terminal.title == "leftright")
        #expect(terminal.snapshot().rows.map(\.text) == ["XY", "", ""])
        #expect(reply == Array("\u{1b}[1;3R".utf8))
    }
}
