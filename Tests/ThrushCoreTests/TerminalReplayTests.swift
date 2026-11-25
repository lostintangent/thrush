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
        // A restored focus mode answers with the new host's focus, which starts out.
        let replies = resumed.receive(original.replayBytes())
        #expect(replies == (original.modes.sendFocus ? Array("\u{1b}[O".utf8) : []))
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
        (6, e + "]4;1;#12", "34\u{07}" + e + "]4;1;?\u{07}Z"),
        (6, e + "]10;#111;#2", "22;?\u{07}" + e + "]10;?\u{07}Z"),
        (6, e + "]4;1;#123\u{07}" + e + "]104;", "1\u{07}" + e + "]4;1;?\u{07}Z"),
        (6, e + "[2;3r" + e + "[?6h" + e + "[1;2HAB", e + "[6n" + e + "[2;1HZ" + e + "[3AY"),
        (4, e + "[2;3r" + e + "[?6h" + e + "[2;1HABCD", "EF" + e + "[6n"),
        (4, e + "[2;3r" + e + "[?6h" + e + "[2;1HABCD", "\u{0301}E" + e + "[6n"),
        (6, e + "[2;3r" + e + "[?6h" + e + "(A" + e + "7" + e + "(B" + e + "8", "#" + e + "[6n"),
        (6, e + "[2;3r" + e + "[?6h" + e + "[2;2HM" + e + "[?1049h" + e + "[2;2HA",
         e + "[6n" + e + "[?1049l" + e + "[6nZ"),
        (6, e + "[?1049h" + e + "[2;3r" + e + "[?6h" + e + "[1;3HQ",
         e + "[6n" + e + "[?1049l" + e + "[6n" + e + "[HZ"),
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
        #expect(a.programColors == b.programColors)
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

@Test func programColorsOutliveThemeChangesAndResumes() {
    let e = "\u{1b}"
    let sets = Array((e + "]4;1;#102030\u{07}" + e + "]11;rgb:40/50/60\u{07}").utf8)
    let query = Array((e + "]4;1;?;2;?\u{07}" + e + "]10;?;?;?\u{07}").utf8)
    var ansi = Terminal.Palette.default.ansi
    ansi[1] = .init(red: 0xaa, green: 0, blue: 0)
    ansi[2] = .init(red: 0, green: 0xaa, blue: 0)
    let theme = Terminal.Palette(foreground: .init(red: 0x11, green: 0x11, blue: 0x11),
                                 background: .init(red: 0xee, green: 0xee, blue: 0xee), ansi: ansi)
    let cursor = Terminal.RGB(red: 0x12, green: 0x34, blue: 0x56)
    var server = Terminal(size: .init(columns: 4, rows: 2))
    var client = Terminal(size: server.size)
    _ = server.receive(sets)
    _ = client.receive(sets)
    let before = client.snapshot()
    #expect(client.receive(query).count > 0)
    #expect(client.snapshot().generation == before.generation)
    client.palette = theme
    client.cursorColor = cursor
    #expect(client.snapshot().generation != before.generation)
    #expect(client.snapshot().programColors == before.programColors)
    let replies = client.receive(query)
    #expect(String(decoding: replies, as: UTF8.self) == [
        "]4;1;rgb:1010/2020/3030", "]4;2;rgb:0000/aaaa/0000",
        "]10;rgb:1111/1111/1111", "]11;rgb:4040/5050/6060", "]12;rgb:1212/3434/5656",
    ].map { e + $0 + e + "\\" }.joined())
    var resumed = Terminal(size: server.size, palette: theme, cursorColor: cursor)
    #expect(resumed.receive(server.replayBytes()).isEmpty)
    #expect(resumed.programColors == client.programColors)
    #expect(resumed.receive(query) == replies)
}

@Test func partialStatusRequestGetsTheSameAnswerAfterReplay() {
    let e = "\u{1b}"
    let cases = [
        (e + "[2;3r" + e + "P$", "qr" + e + "\\", e + "P1$r2;3r" + e + "\\"),
        (e + "P1;2$qr", e + "\\", e + "P1$r1;3r" + e + "\\"),
        (e + "P$q\"", "p" + e + "\\", e + "P1$r61;1\"p" + e + "\\"),
        (e + "P$qm\u{07}", e + "\\", e + "P0$r" + e + "\\"),
        (e + "P+q544e", e + "\\", ""),
    ]
    for (prefix, suffix, reply) in cases {
        var original = Terminal(size: .init(columns: 6, rows: 3))
        _ = original.receive(Array(prefix.utf8))
        var resumed = Terminal(size: original.size)
        #expect(resumed.receive(original.replayBytes()).isEmpty)
        #expect(String(decoding: original.receive(Array(suffix.utf8)), as: UTF8.self) == reply)
        #expect(String(decoding: resumed.receive(Array(suffix.utf8)), as: UTF8.self) == reply)
    }
}

@Test func partialControlStringsKeepTheirLengthLimit() {
    // Each start is filled to exactly the limit, so one more character makes it overlong.
    for (start, length, end) in [("\u{1b}]10;?;?;", 4, "!\u{07}"), ("\u{1b}P$q", 0, "!\u{1b}\\")] {
        var original = Terminal(size: .init(columns: 4, rows: 2))
        _ = original.receive(start.utf8)
        _ = original.receive(Array(repeating: UInt8(ascii: "x"), count: 10_000_000 - length))
        var resumed = Terminal(size: original.size)
        #expect(resumed.receive(original.replayBytes()).isEmpty)
        #expect(original.receive(Array(end.utf8)).isEmpty)
        #expect(resumed.receive(Array(end.utf8)).isEmpty)
    }
}
