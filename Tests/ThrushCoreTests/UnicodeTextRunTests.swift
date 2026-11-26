import Testing
import ThrushCore

@Test func wideTextWrapsAndResumesAcrossAnEncodedControl() {
    var terminal = Terminal(size: .init(columns: 4, rows: 3))
    let wide = "界\u{301}"
    let csi = "\u{9b}"

    _ = terminal.write("abc".utf8)
    _ = terminal.write(Array(wide.utf8))
    let retained = terminal.snapshot()
    #expect(retained.rows.map(\.text) == ["abc", wide, ""])
    #expect(retained.rows.map(\.isWrapped) == [false, true, false])
    #expect(retained.cursorRow == 1 && retained.cursorColumn == 2)
    #expect(retained.rows[1][0].width == 2 && retained.rows[1][1].width == 0)

    // The encoded CSI interrupts printable UTF-8 in the middle of this buffer.
    let switchBuffer = Array(("é" + csi + "?1049h" + wide).utf8)
    _ = terminal.write(switchBuffer.span)
    let alternate = terminal.snapshot()
    #expect(alternate.isAlternate)
    #expect(alternate.rows.map(\.text) == ["", "", wide])
    #expect(alternate.rows.map(\.isWrapped) == [false, false, true])
    #expect(alternate.cursorRow == 2 && alternate.cursorColumn == 2)

    let reply = terminal.write(Array((csi + "?1049l" + csi + "6n").utf8))
    #expect(reply == Array("\u{1b}[2;4R".utf8))
    let restored = terminal.snapshot()
    #expect(!restored.isAlternate)
    #expect(restored.rows[1].text == wide + "é")
    #expect(restored.rows[1][2].text == "é")
    #expect(retained.rows[1][2].text.isEmpty && retained.rows[1].text == wide)
}

@Test func asciiContinuesAnAppendingRunAndEndsAnOverwritingOne() {
    var terminal = Terminal(size: .init(columns: 6, rows: 3))
    let accented = Array("界ae\u{301}é".utf8)

    // The chunk ends inside é, after ASCII the run carried.
    _ = terminal.write(Array(accented.dropLast()))
    _ = terminal.write([accented.last!] + Array("界x".utf8))
    var screen = terminal.snapshot()
    #expect(screen.rows.map(\.text) == ["界ae\u{301}é", "界x", ""])
    #expect(screen.rows[0][3].text == "e\u{301}")
    #expect(screen.rows.map(\.isWrapped) == [false, true, false])
    #expect(screen.cursorRow == 1 && screen.cursorColumn == 3)

    _ = terminal.write(Array("\u{1b}[Hé1界2".utf8))
    screen = terminal.snapshot()
    #expect(screen.rows[0].text == "é1界2")
    #expect(screen.rows[0][2].width == 2 && screen.rows[0][3].width == 0)
    #expect(screen.cursorRow == 0 && screen.cursorColumn == 5)
}
