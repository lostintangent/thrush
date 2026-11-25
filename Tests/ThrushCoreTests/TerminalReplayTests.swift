import Testing
import ThrushCore
import ThrushFixtures

@Test(arguments: ReplayFixture.names)
func serializedCheckpointsRestoreTheRecordedScreen(_ name: String) throws {
    try checkSerialization(ReplayFixture.load(named: name))
}

@Test func serializedHandsetVimRestoresBothBuffers() throws {
    try checkSerialization(ReplayFixture.load(named: "vim-resume", subdirectory: nil))
}

private func checkSerialization(_ fixture: ReplayFixture) throws {
    var original = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    var resumed = original
    for (index, event) in fixture.events.enumerated() {
        event.applyReady(to: &original)
        event.applyReady(to: &resumed)
        if let size = event.resize {
            // A resize can reveal columns clipped from an alternate grid. Those columns
            // cannot be addressed by a VT replay sent at the smaller size.
            resumed = original
            original.resize(to: .init(columns: size.columns, rows: size.rows))
            resumed.resize(to: original.size)
        }
        if let palette = event.palette { original.palette = palette; resumed.palette = palette }
        _ = original.receive(event.bytes)
        _ = resumed.receive(event.bytes)
        guard event.checkpoint != nil else { continue }
        // This checkpoint sees all subsequent output on the previous reconstruction.
        do { try event.verify(resumed.snapshot(), serialized: event.resize == nil) } catch { throw ReplayFailure("\(fixture.name) #\(index) continued: \(error)") }
        resumed = Terminal(size: original.size, palette: original.palette)
        let replies = resumed.receive(original.replayBytes())
        #expect(replies.isEmpty)
        do { try event.verify(resumed.snapshot(), serialized: true) } catch { throw ReplayFailure("\(fixture.name) #\(index) fresh: \(error)") }
        #expect(resumed.title == original.title)
    }
}

private struct ReplayFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Test func continuedPrintingAfterReplay() {
    let e = "\u{1b}"
    let cases = [
        (6, "ABCD" + e + "[2G" + e + "[4hX", "Y"),
        (4, "ABC#" + e + "(A", "#"),
        (4, "ABCD" + e + "[0m", "\u{0301}"),
        (4, "ABCD", "\u{0301}E"),
        (4, "ab" + e + "[0m\u{0301}", "XY"),
        (6, e + "(A" + e + "7" + e + "(B" + e + "8", "\u{0f}#"),
        (6, e + "[?47h" + e + "[2;3H" + e + "7" + e + "[?47l", e + "[?47h" + e + "8Z"),
        (6, e + "[" + String(repeating: "0;", count: 32), "31mZ"),
        (6, e + "]2;title", " end\u{07}Z"),
        (6, e + "[38:2::1:2", ":3mZ"),
        (6, e + "]4;16;?;2", ";?\u{07}Z"),
    ]
    func assertContinuation(_ columns: Int, prefix: [UInt8], suffix: [UInt8]) {
        var before = Terminal(size: .init(columns: columns, rows: 3))
        _ = before.receive(prefix)
        var resumed = Terminal(size: before.size)
        #expect(resumed.receive(before.replayBytes()).isEmpty)
        #expect(before.receive(suffix) == resumed.receive(suffix))
        let a = before.snapshot(), b = resumed.snapshot()
        #expect(a.cursorColumn == b.cursorColumn && a.cursorRow == b.cursorRow)
        #expect(a.modes == b.modes && before.title == resumed.title)
        for row in 0..<a.size.rows {
            for col in 0..<columns { #expect(a.rows[row][col] == b.rows[row][col]) }
        }
    }
    for (cols, prefix, suffix) in cases {
        assertContinuation(cols, prefix: Array(prefix.utf8), suffix: Array(suffix.utf8))
    }
    for bytes in ["é", "界", "🐥"].map({ Array($0.utf8) }) {
        for split in 1..<bytes.count {
            assertContinuation(8, prefix: Array(bytes.prefix(split)), suffix: Array(bytes.dropFirst(split)))
        }
    }
}


@Test func partialColorQueryKeepsItsLengthLimit() {
    var original = Terminal(size: .init(columns: 4, rows: 2))
    _ = original.receive("\u{1b}]10;?;?;".utf8)
    _ = original.receive(Array(repeating: UInt8(ascii: "x"), count: 10_000_000 - 4))
    var resumed = Terminal(size: original.size)
    #expect(resumed.receive(original.replayBytes()).isEmpty)
    let end = Array("!\u{07}".utf8)
    #expect(original.receive(end).isEmpty)
    #expect(resumed.receive(end).isEmpty)
}
