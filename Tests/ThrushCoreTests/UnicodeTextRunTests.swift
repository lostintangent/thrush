import Testing
import ThrushCore

@Test func wideTextWrapsAndResumesAcrossAnEncodedControl() {
    var terminal = Terminal(size: .init(columns: 4, rows: 3))
    let wide = "界\u{301}"
    let csi = "\u{9b}"

    _ = terminal.receive("abc".utf8)
    _ = terminal.receive(Array(wide.utf8))
    let retained = terminal.snapshot()
    #expect(retained.rows.map(\.text) == ["abc", wide, ""])
    #expect(retained.rows.map(\.isWrapped) == [false, true, false])
    #expect(retained.cursorRow == 1 && retained.cursorColumn == 2)
    #expect(retained.rows[1][0].width == 2 && retained.rows[1][1].width == 0)

    // The encoded CSI interrupts printable UTF-8 in the middle of this buffer.
    let switchBuffer = Array(("é" + csi + "?1049h" + wide).utf8)
    _ = terminal.receive(switchBuffer.span)
    let alternate = terminal.snapshot()
    #expect(alternate.isAlternate)
    #expect(alternate.rows.map(\.text) == ["", "", wide])
    #expect(alternate.rows.map(\.isWrapped) == [false, false, true])
    #expect(alternate.cursorRow == 2 && alternate.cursorColumn == 2)

    let reply = terminal.receive(Array((csi + "?1049l" + csi + "6n").utf8))
    #expect(reply == Array("\u{1b}[2;4R".utf8))
    let restored = terminal.snapshot()
    #expect(!restored.isAlternate)
    #expect(restored.rows[1].text == wide + "é")
    #expect(restored.rows[1][2].text == "é")
    #expect(retained.rows[1][2].text.isEmpty && retained.rows[1].text == wide)
}
