import Testing
import ThrushCore
import ThrushFixtures

@Test func windowTitleAtEverySplitMatchesReference() throws {
    for example in try WindowTitleFixture.load().cases {
        var terminal = Terminal(size: .init(columns: 16, rows: 4))
        for step in example.steps {
            for split in 0...step.bytes.count {
                var fragmented = terminal
                _ = fragmented.write(step.bytes.prefix(split))
                _ = fragmented.write(step.bytes.dropFirst(split))
                #expect(fragmented.title == step.title, "\(example.name), byte split \(split)")
            }
            _ = terminal.write(step.bytes)
            #expect(terminal.title == step.title, "\(example.name)")
        }
    }
}

@Test(arguments: [1, Int.max])
func titlesInCompleteCodexRecording(chunkLimit: Int) throws {
    let fixture = try Recording.load(named: "codex-session")
    let oracle = try WindowTitleFixture.load().codex
    let indices = oracle.checkpoints.map(\.eventIndex)
    try #require(fixture.sha256 == oracle.fixtureSHA256)
    try #require(indices.first == 0 && indices.last == fixture.events.count - 1)
    try #require(indices == Set(indices).sorted())
    try #require(oracle.checkpoints.contains { !$0.title.isEmpty })
    try #require(oracle.checkpoints.last?.title == "")

    var expected = oracle.checkpoints.makeIterator()
    var next = expected.next()
    var expectedTitle = ""
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    for (index, event) in fixture.events.enumerated() {
        if let resize = event.resize { terminal.resize(to: .init(columns: resize.columns, rows: resize.rows)) }
        var bytes = event.bytes[...]
        while !bytes.isEmpty {
            let chunk = bytes.prefix(chunkLimit)
            _ = terminal.write(chunk)
            bytes = bytes.dropFirst(chunk.count)
        }
        if let checkpoint = next, checkpoint.eventIndex == index {
            expectedTitle = checkpoint.title
            next = expected.next()
        }
        #expect(terminal.title == expectedTitle, "Codex event \(index) (\(event.name))")
    }
    #expect(next == nil)
    #expect(terminal.title == "")
}

@Test func titleRunHonorsTheUTF16LimitAcrossChunks() {
    var pending = Terminal(size: .init(columns: 16, rows: 4))
    _ = pending.write("\u{1B}]2;previous\u{07}\u{1B}]2;".utf8)
    _ = pending.write([UInt8](repeating: 0x61, count: 9_999_997))
    let smile = Array("🙂".utf8)
    _ = pending.write(smile.prefix(2))
    _ = pending.write(smile.suffix(2))
    #expect(pending.title == "previous")

    var exact = pending
    _ = exact.write("z\u{07}".utf8)
    #expect(exact.title.utf16.count == 10_000_000)
    #expect(exact.title.hasSuffix("a🙂z"))

    _ = pending.write("zz\u{07}".utf8)
    #expect(pending.title == "previous")
    _ = pending.write("\u{1B}]0;\u{1B}\\".utf8)
    #expect(pending.title.isEmpty)
}

@Test func printableBytesAfterIncompleteUTF8InATitleResumeAtTheSameByte() {
    var terminal = Terminal(size: .init(columns: 16, rows: 4))
    _ = terminal.write(Array("\u{1B}]2;one ".utf8) + [0xf0, 0x9f])
    _ = terminal.write("two\u{07}screen".utf8)
    #expect(terminal.title == "one two")
    #expect(terminal.text(inRow: 0) == "screen")

    _ = terminal.write("\u{1B}]2;discard this payload\u{18}!".utf8)
    #expect(terminal.title == "one two")
    #expect(terminal.text(inRow: 0) == "screen!")
}
