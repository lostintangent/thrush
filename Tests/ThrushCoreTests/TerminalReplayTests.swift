import Testing
import ThrushCore
import ThrushFixtures

@Test(arguments: Recording.names)
func serializedCheckpointsRestoreTheRecordedScreen(_ name: String) throws {
    try checkSerialization(Recording.load(named: name))
}

@Test func serializedHandsetVimRestoresBothBuffers() throws {
    try checkSerialization(Recording.load(named: "vim-resume", subdirectory: "recordings/phone"))
}

private func checkSerialization(_ fixture: Recording) throws {
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
        _ = original.write(event.bytes)
        _ = resumed.write(event.bytes)
        guard let expected = event.checkpoint else { continue }
        // This checkpoint sees all subsequent output on the previous reconstruction.
        try check(resumed, against: event.resize == nil ? replayed(expected) : expected, "\(fixture.name) #\(index) continued")
        resumed = Terminal(size: original.size, palette: original.palette)
        // A restored focus mode answers with the new host's focus, which starts out.
        let reply = resumed.write(original.replayBytes())
        #expect(reply == (original.modes.sendFocus ? Array("\u{1b}[O".utf8) : []))
        try check(resumed, against: replayed(expected), "\(fixture.name) #\(index) fresh")
    }
}

private func check(_ terminal: Terminal, against expected: Checkpoint, _ context: String) throws {
    let differences = Checkpoint(terminal, name: expected.name, includesHistory: true).differences(from: expected)
    if let first = differences.first { throw ReplayFailure("\(context): \(first)") }
}

/// The screens a replay can restore. A glyph clipped at the right margin can't be printed whole,
/// so its one visible cell stays empty. Widening a clipped glyph may leave an old character under
/// its second column, and printing the glyph restores the continuation.
private func replayed(_ checkpoint: Checkpoint) -> Checkpoint {
    let columns = checkpoint.size[0]
    func replayed(_ lines: [Checkpoint.Line]) -> [Checkpoint.Line] {
        lines.map { line in
            var line = line
            let clipped = line.cells.count == columns && line.cells.last?.width == 2
            for column in line.cells.indices {
                if column > 0, line.cells[column - 1].width == 2, line.cells[column].width != 0 {
                    line.cells[column] = .init(text: "", width: 0, style: line.cells[column - 1].style)
                } else if clipped && column == columns - 1 {
                    line.cells[column] = .blank
                }
            }
            while line.cells.last == .blank { line.cells.removeLast() }
            return line
        }
    }
    func replayed(_ screen: Checkpoint.Screen) -> Checkpoint.Screen {
        var screen = screen
        screen.history = screen.history.map(replayed)
        screen.visible = replayed(screen.visible)
        return screen
    }
    var checkpoint = checkpoint
    checkpoint.active = replayed(checkpoint.active)
    checkpoint.normal = checkpoint.normal.map(replayed)
    return checkpoint
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
        (6, e + "]52;c;aGVs", "bG8=\u{07}Z"),
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
        (6, "ab", e + "[2bZ"),
        (6, "ab" + e + "[", "2bZ"),
        (6, "ab" + e, "[2bZ"),
        (6, "a\u{0301}", e + "[2bZ"),
        (6, "ab" + e + "[1m", "\u{0301}Z"),
        (6, "ab" + e + "[1m", e + "[2bZ"),
        (6, "ab" + e + "[1<2m", e + "[2bZ"),
        (6, "ab" + e + "[1<2m", "\u{0301}Z"),
        (6, "ab\u{9b}", "2bZ"),
        (4, "ABCD" + e + "[", "2b"),
        (4, e + "[?45hABCD", "\u{8}Z"),
        (4, e + "[?45hABCDE", "\u{8}\u{8}Z"),
        (6, e + "[>1u" + e + "[>5u" + e + "[?1049h" + e + "[>4u" + e + "[?1049l",
         e + "[?u" + e + "[<u" + e + "[?u" + e + "[?1049h" + e + "[?u" + e + "[<u" + e + "[?uZ"),
        (6, e + "[>1u" + e + "[?1049h" + e + "[=5u", e + "[?u" + e + "[?1049l" + e + "[?u" + e + "[<u" + e + "[?uZ"),
    ]
    func assertContinuation(_ columns: Int, prefix: [UInt8], suffix: [UInt8]) {
        var before = Terminal(size: .init(columns: columns, rows: 3))
        _ = before.write(prefix)
        var resumed = Terminal(size: before.size)
        #expect(resumed.write(before.replayBytes()).isEmpty)
        #expect(before.write(suffix) == resumed.write(suffix))
        let a = before.snapshot(), b = resumed.snapshot()
        #expect(a.cursorColumn == b.cursorColumn && a.cursorRow == b.cursorRow)
        #expect(a.modes == b.modes && before.title == resumed.title && before.copiedText == resumed.copiedText)
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
    _ = server.write(sets)
    _ = client.write(sets)
    let before = client.snapshot()
    #expect(client.write(query).count > 0)
    #expect(client.snapshot().generation == before.generation)
    client.palette = theme
    client.cursorColor = cursor
    #expect(client.snapshot().generation != before.generation)
    #expect(client.snapshot().programColors == before.programColors)
    let reply = client.write(query)
    #expect(String(decoding: reply, as: UTF8.self) == [
        "]4;1;rgb:1010/2020/3030", "]4;2;rgb:0000/aaaa/0000",
        "]10;rgb:1111/1111/1111", "]11;rgb:4040/5050/6060", "]12;rgb:1212/3434/5656",
    ].map { e + $0 + e + "\\" }.joined())
    var resumed = Terminal(size: server.size, palette: theme, cursorColor: cursor)
    #expect(resumed.write(server.replayBytes()).isEmpty)
    #expect(resumed.programColors == client.programColors)
    #expect(resumed.write(query) == reply)
}

@Test func appearanceReportsFollowMode2031ThroughResetsAndResumes() {
    let e = "\u{1b}"
    let dark = e + "[?997;1n", light = e + "[?997;2n"
    func reply(_ terminal: inout Terminal, _ text: String) -> String {
        String(decoding: terminal.write(Array(text.utf8)), as: UTF8.self)
    }
    // A terminal whose app hasn't chosen a theme leaves the question unanswered.
    var terminal = Terminal(size: .init(columns: 4, rows: 2))
    #expect(reply(&terminal, e + "[?996n" + e + "[?2031$p") == e + "[?2031;2$y")
    terminal.appearance = .dark
    #expect(reply(&terminal, e + "[?996n") == dark)
    #expect(terminal.encode(.appearance(.light)).isEmpty)

    // Setting the mode reports nothing. The program asks, then hears each change.
    #expect(reply(&terminal, e + "[?2031h").isEmpty)
    #expect(reply(&terminal, e + "[?2031$p" + e + "[?996n") == e + "[?2031;1$y" + dark)
    #expect(String(decoding: terminal.encode(.appearance(.light)), as: UTF8.self) == light)

    // A resumed shell keeps asking, and a new shell starts with the app's appearance.
    var resumed = Terminal(size: terminal.size)
    resumed.appearance = .light
    #expect(resumed.write(terminal.replayBytes()).isEmpty)
    #expect(resumed.modes.reportAppearance)
    terminal.startNewShell(at: terminal.size)
    #expect(!terminal.modes.reportAppearance && terminal.appearance == .dark)

    // DECSTR keeps the reports, as Ghostty does, and RIS ends them but still knows the theme.
    _ = terminal.write(Array((e + "[?2031h" + e + "[!p").utf8))
    #expect(terminal.modes.reportAppearance)
    #expect(reply(&terminal, e + "c" + e + "[?2031$p" + e + "[?996n") == e + "[?2031;2$y" + dark)
    #expect(terminal.encode(.appearance(.light)).isEmpty)
}

/// A resumed client can apply kitty flags ThrushCore doesn't, keep a program's colors through a reset,
/// or have fewer rows. The replay hands on every flag the program pushed, restores the theme's colors
/// before setting the program's, and leaves out the blank rows a shorter client would scroll by.
@Test func replaySuitsAClientThatDiffers() {
    let e = "\u{1b}"
    var terminal = Terminal(size: .init(columns: 8, rows: 6))
    let reply = terminal.write(Array((e + "[>3u" + e + "]11;#000000\u{07}hi" + e + "[?u").utf8))
    #expect(reply == Array((e + "[?1u").utf8))
    let replay = String(decoding: terminal.replayBytes(), as: UTF8.self)
    #expect(replay.contains(e + "[>3u"))
    #expect(replay.contains(["]104", "]110", "]111", "]112", "]11;rgb:00/00/00"].map { e + $0 + "\u{7}" }.joined()))
    var shorter = Terminal(size: .init(columns: 8, rows: 3))
    _ = shorter.write(terminal.replayBytes())
    #expect(shorter.snapshot().rows[0].text == "hi")
}

/// A replay writes each style as what it adds, with the 16 colors in their short forms. A style that
/// turns anything off starts over from 0, since 22 turns off bold and dim together.
@Test func replayWritesEachStyleAsWhatItAdds() {
    let changes = [
        ("1", "1"), ("2", "2"), ("22;2", "0;2"), ("1", "1"), ("22;1", "0;1"), ("0;31", "0;31"), ("32", "32"),
        ("39", "0"), ("4:3", "4:3"), ("4", "4"), ("24", "0"), ("91;44", "91;44"),
        ("38;5;16;58;5;3", "38;5;16;58;5;3"), ("7", "7"), ("27", "0;38;5;16;44;58;5;3"),
    ]
    let text = changes.enumerated().map { "\u{1b}[\($1.0)m" + String(UnicodeScalar(UInt8(97 + $0))) }.joined()
    let replay = checkReplay(of: text, columns: 20)
    // The row also holds the saved cursor, whose default style is stored before the pen returns.
    let saved = ["0", "38;5;16;44;58;5;3"]
    #expect(replay.matches(of: /\x1B\[([0-9;:]*)m/).map { String($0.1) } == changes.map(\.1) + saved)

    // Turning off any one rendition keeps the others.
    for off in ["22", "23", "24", "25", "27", "28", "29", "55", "39", "49", "59"] {
        checkReplay(of: "\u{1b}[1;2;3;4;5;7;8;9;53;31;42;58;5;3mA\u{1b}[\(off)mB", columns: 4)
    }
}

@discardableResult
private func checkReplay(of text: String, columns: Int) -> String {
    var original = Terminal(size: .init(columns: columns, rows: 2))
    _ = original.write(Array(text.utf8))
    let replay = original.replayBytes()
    var resumed = Terminal(size: original.size)
    _ = resumed.write(replay)
    // One more character shows the pen each continues with.
    let styles = { (terminal: inout Terminal) in
        _ = terminal.write(Array("Z".utf8))
        let row = terminal.snapshot().rows[0]
        return (0..<columns).map { row[$0].style }
    }
    #expect(styles(&resumed) == styles(&original), "\(text.debugDescription)")
    return String(decoding: replay, as: UTF8.self)
}

@Test func partialRequestsGetTheSameAnswerAfterReplay() {
    let e = "\u{1b}"
    let cases = [
        (e + "[2;3r" + e + "P$", "qr" + e + "\\", e + "P1$r2;3r" + e + "\\"),
        (e + "P1;2$qr", e + "\\", e + "P1$r1;3r" + e + "\\"),
        (e + "P$q\"", "p" + e + "\\", e + "P1$r61;1\"p" + e + "\\"),
        (e + "P$qm\u{07}", e + "\\", e + "P0$r" + e + "\\"),
        (e + "P+q544e", e + "\\", ""),
        (e + "P+q4d", "73" + e + "\\", e + "P1+r4d73=1B5D35323B25703125733B257032257307" + e + "\\"),
    ]
    for (prefix, suffix, reply) in cases {
        var original = Terminal(size: .init(columns: 6, rows: 3))
        _ = original.write(Array(prefix.utf8))
        var resumed = Terminal(size: original.size)
        #expect(resumed.write(original.replayBytes()).isEmpty)
        #expect(String(decoding: original.write(Array(suffix.utf8)), as: UTF8.self) == reply)
        #expect(String(decoding: resumed.write(Array(suffix.utf8)), as: UTF8.self) == reply)
    }
}

@Test func partialControlStringsKeepTheirLengthLimit() {
    // Each start is filled to exactly the limit, so one more character makes it overlong.
    for (start, length, end) in [("\u{1b}]10;?;?;", 4, "!\u{07}"), ("\u{1b}P$q", 0, "!\u{1b}\\")] {
        var original = Terminal(size: .init(columns: 4, rows: 2))
        _ = original.write(start.utf8)
        _ = original.write(Array(repeating: UInt8(ascii: "x"), count: 10_000_000 - length))
        var resumed = Terminal(size: original.size)
        #expect(resumed.write(original.replayBytes()).isEmpty)
        #expect(original.write(Array(end.utf8)).isEmpty)
        #expect(resumed.write(Array(end.utf8)).isEmpty)
    }
}
