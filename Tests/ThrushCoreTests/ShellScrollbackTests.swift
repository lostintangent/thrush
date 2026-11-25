import Testing
import ThrushCore

@Test(arguments: [false, true])
func newShellArchivesTheNormalBuffer(inAlternateScreen: Bool) throws {
    var terminal = Terminal(size: .init(columns: 6, rows: 4))
    _ = terminal.receive("one\r\ntwo\r\n\r\n\u{1b}[1;31mred\u{1b}[0m\r\n ".utf8)
    let normal = terminal.snapshot()
    #expect(normal.history.map(\.text) == ["one"])
    #expect(normal.rows.map(\.text) == ["two", "", "red", " "])
    if inAlternateScreen {
        _ = terminal.receive("\u{1b}[?1049hVim".utf8)
    }

    terminal.startNewShell(at: terminal.size)
    let first = terminal.snapshot()
    try #require(first.history.map(\.text) == ["one", "two", "", "red", " "])
    #expect(first.currentShellHistoryCount == 0)
    #expect(first.history[3][0].style.bold && first.history[3][0].style.foreground == .indexed(1))
    #expect(first.rows.map(\.text) == ["", "", "", ""])
    #expect(!first.isAlternate && first.cursorRow == 0 && first.cursorColumn == 0)

    // A line erased to a color is visible content even though its text is empty.
    _ = terminal.receive("B\r\n\u{1b}[44m\u{1b}[2K\u{1b}[0m".utf8)
    terminal.startNewShell(at: terminal.size)
    terminal.startNewShell(at: terminal.size)
    let second = terminal.snapshot()
    #expect(second.history.map(\.text) == ["one", "two", "", "red", " ", "B", ""])
    #expect(second.history.last?[5].style.background == .indexed(4))
    #expect(first.history.last?.text == " ")
    #expect(normal.rows[2][0] == first.history[3][0])

    // Erasing the only glyph with ECH leaves an empty continuation of the preceding row.
    _ = terminal.receive("123456Z\r\u{1b}[X".utf8)
    terminal.startNewShell(at: terminal.size)
    let end = terminal.snapshot().history.suffix(2)
    #expect(end.map(\.text) == ["123456", ""])
    #expect(end.last?.isWrapped == true)
}

@Test(arguments: [false, true])
func shellBoundaryPreservesHostSettingsAndResetsProgramState(replaying: Bool) {
    let palette = Terminal.Palette(foreground: .init(red: 10, green: 20, blue: 30),
                                   background: .init(red: 40, green: 50, blue: 60), ansi: Terminal.Palette.default.ansi)
    let cursor = Terminal.RGB(red: 70, green: 80, blue: 90)
    let size = Terminal.Size(columns: 8, rows: 3)
    var terminal = Terminal(size: size, palette: palette, cursorColor: cursor)
    terminal.isFocused = true
    _ = terminal.receive("\u{1b}]2;editor\u{7}\u{1b}]11;#abc\u{7}\u{1b}[?25l\u{1b}[?2004h\u{1b}[4h\u{1b}[31m\u{1b}(0q".utf8)
    #expect(!terminal.programColors.isEmpty && terminal.title == "editor")
    // The title collector and UTF-8 decoder each need the other half of this chunk.
    _ = terminal.receive(Array("\u{1b}]2;unfinished".utf8) + [0xe7, 0x95])

    if replaying { terminal.prepareForReplay(at: size) } else { terminal.startNewShell(at: size) }
    let fresh = terminal.snapshot()
    #expect(fresh.palette == palette && terminal.cursorColor == cursor && terminal.isFocused)
    #expect(fresh.modes == Terminal(size: size).modes)
    #expect(fresh.cursorVisible && fresh.cursorRow == 0 && fresh.cursorColumn == 0)
    #expect(terminal.programColors.isEmpty && terminal.title.isEmpty)
    _ = terminal.receive([0x8c, 0x07, UInt8(ascii: "q")])
    #expect(terminal.title.isEmpty && terminal.text(inRow: 0) == "q")
    #expect(terminal.snapshot().rows[0][0].style == .init())
    #expect(terminal.receive("\u{1b}[?1004h".utf8) == Array("\u{1b}[I".utf8))
}

@Test func repeatedReplayKeepsOnlyPreviousShellsAndHonorsErasedHistory() {
    let size = Terminal.Size(columns: 8, rows: 3)
    var local = Terminal(size: size)
    _ = local.receive("old".utf8)
    local.startNewShell(at: size)
    var server = Terminal(size: size)
    let output = "a\r\nb\r\nc\r\nd\r\ne"
    _ = server.receive(output.utf8)
    _ = local.receive(output.utf8)
    let replay = server.replayBytes()
    #expect(local.replayBytes() == replay)
    for _ in 0..<2 {
        #expect(local.snapshot().history.map(\.text) == ["old", "a", "b"])
        #expect(local.snapshot().currentShellHistoryCount == 2)
        local.prepareForReplay(at: size)
        #expect(local.snapshot().history.map(\.text) == ["old"])
        #expect(local.snapshot().rows.allSatisfy { $0.text.isEmpty })
        _ = local.receive(replay)
        #expect(local.snapshot().rows.map(\.text) == ["c", "d", "e"])
    }
    _ = local.receive("\u{1b}[3J".utf8)
    _ = server.receive("\u{1b}[3J".utf8)
    #expect(local.snapshot().history.isEmpty)
    local.prepareForReplay(at: size)
    _ = local.receive(server.replayBytes())
    #expect(local.snapshot().history.isEmpty)
    #expect(local.snapshot().rows.map(\.text) == ["c", "d", "e"])
}

@Test func previousShellWrapsReflowAtTheNextGridWidth() throws {
    var terminal = Terminal(size: .init(columns: 4, rows: 4))
    _ = terminal.receive("\u{1b}[1mABCDEF\u{1b}[0m\r\n-".utf8)
    let wide = Terminal.Size(columns: 6, rows: 3)
    terminal.startNewShell(at: wide)
    let first = terminal.snapshot()
    #expect(first.size == wide)
    try #require(first.history.map(\.text) == ["ABCDEF", "-"])
    #expect(first.history[0][5].style.bold)

    _ = terminal.receive("a\r\nb\r\nc".utf8)
    terminal.resize(to: .init(columns: 6, rows: 5))
    let taller = terminal.snapshot()
    #expect(taller.history.map(\.text) == ["ABCDEF", "-"])
    #expect(taller.rows.map(\.text) == ["a", "b", "c", "", ""])

    let narrow = Terminal.Size(columns: 3, rows: 3)
    terminal.prepareForReplay(at: narrow)
    let second = terminal.snapshot()
    #expect(second.size == narrow)
    try #require(second.history.map(\.text) == ["ABC", "DEF", "-"])
    #expect(second.history.map(\.isWrapped) == [false, true, false])
    #expect(second.history[1][2].style.bold)
    #expect(first.history[0].text == "ABCDEF")
}

@Test func replacementAndLiveOutputShareTheThousandRowLimit() {
    let size = Terminal.Size(columns: 8, rows: 2)
    var terminal = Terminal(size: size)
    _ = terminal.receive((0..<1006).map(String.init).joined(separator: "\r\n").utf8)
    terminal.startNewShell(at: size)
    #expect(terminal.snapshot().history.map(\.text) == (6..<1006).map(String.init))
    // The saved cursor belongs to B. When A scrolls out, B becomes the top live row.
    let output = "A\r\nB\u{1b}7\r\nC\u{1b}8\u{1b}[6n"
    var server = Terminal(size: size)
    let expected = Array("\u{1b}[1;2R".utf8)
    #expect(server.receive(output.utf8) == expected)
    #expect(terminal.receive(output.utf8) == expected)
    #expect(terminal.snapshot().history.map(\.text) == (7..<1006).map(String.init) + ["A"])
    #expect(terminal.snapshot().rows.map(\.text) == ["B", "C"])
}
