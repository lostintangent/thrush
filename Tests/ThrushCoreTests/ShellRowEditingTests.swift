import Testing
@testable import ThrushCore

private let csi = "\u{1b}["

@Test func rowEditsMoveCompleteStyledCellsAndPreserveEarlierSnapshots() {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.receive(("A" + csi + "1;31;44m界\u{301}BC" + csi + "0mDE").utf8)
    let original = terminal.snapshot()
    let wide = original.rows[0][1]
    let continuation = original.rows[0][2]
    #expect(wide.width == 2 && wide.text == "界\u{301}")
    #expect(continuation.width == 0)
    _ = terminal.receive((csi + "1;2H" + csi + "1;33;42m" + csi + "@").utf8)
    let inserted = terminal.snapshot()
    var eraseStyle = Terminal.Style()
    eraseStyle.background = .indexed(2)
    let blank = Terminal.Cell(text: "", width: 1, style: eraseStyle)
    #expect(inserted.rows[0][1] == blank)
    #expect(inserted.rows[0][2] == wide)
    #expect(inserted.rows[0][3] == continuation)
    #expect(inserted.rows[0][4] == original.rows[0][3])
    #expect(inserted.rows[0].text == "A 界\u{301}BCDE")
    #expect(inserted.cursorColumn == 1)
    #expect(inserted.rows[1].generation == original.rows[1].generation)
    #expect(inserted.rows[0].generation != original.rows[0].generation)

    _ = terminal.receive((csi + "0P").utf8)
    let deleted = terminal.snapshot()
    #expect(deleted.rows[0].text == original.rows[0].text)
    #expect(deleted.rows[0][1] == wide && deleted.rows[0][2] == continuation)
    #expect(deleted.rows[0][7] == blank)
    #expect(inserted.rows[0][1] == blank && original.rows[0][1] == wide)

    _ = terminal.receive((csi + "99999999999999999999999P").utf8)
    let clipped = terminal.snapshot()
    #expect(clipped.rows[0].text == "A")
    #expect(clipped.cursorColumn == 1)
    #expect((1..<8).allSatisfy { clipped.rows[0][$0] == blank })
}

@Test func insertionAndDeletionRepairWideCellBoundaries() {
    var terminal = Terminal(size: .init(columns: 6, rows: 2))
    _ = terminal.receive(("A界BCD" + csi + "1;3H" + csi + "0@").utf8)
    let row = terminal.snapshot().rows[0]
    // Insertion shifts the original continuation and erases the leading half left of the cursor.
    #expect((0..<6).map { row[$0].text } == ["A", "", "", "", "B", "C"])
    #expect((0..<6).map { row[$0].width } == [1, 1, 1, 0, 1, 1])

    for cursor in [2, 3] {
        var deletion = Terminal(size: .init(columns: 6, rows: 2))
        _ = deletion.receive(("A界BCD" + csi + "1;\(cursor)H" + csi + "P").utf8)
        let row = deletion.snapshot().rows[0]
        #expect(row.text == "A BCD")
        #expect((0..<6).allSatisfy { row[$0].width == 1 })
    }
    _ = terminal.receive(("\rABCD界" + csi + "1;2H" + csi + "@").utf8)
    #expect(terminal.text(inRow: 0) == "A BCD")
    #expect(terminal.snapshot().rows[0][5].width == 1)
}

@Test func tabsAndErasesRespectThePendingWrapColumn() {
    var terminal = Terminal(size: .init(columns: 19, rows: 2))
    _ = terminal.receive("123456789ABCDEFGHIJ".utf8)
    let original = terminal.snapshot().rows[0]
    _ = terminal.receive("\r".utf8)
    for column in [8, 16, 18, 18] {
        _ = terminal.receive("\t".utf8)
        #expect(terminal.snapshot().cursorColumn == column)
        #expect(terminal.snapshot().rows[0].generation == original.generation)
    }
    _ = terminal.receive("x\t".utf8)
    #expect(terminal.snapshot().cursorColumn == 19)
    _ = terminal.receive((csi + "2K").utf8)
    #expect(terminal.snapshot().cursorColumn == 19)
    #expect(terminal.text(inRow: 0).isEmpty)
    _ = terminal.receive("Z".utf8)
    #expect(terminal.snapshot().cursorRow == 1 && terminal.snapshot().rows[1].isWrapped)
    #expect(terminal.text(inRow: 1) == "Z")
    _ = terminal.receive((csi + "2K").utf8)
    #expect(!terminal.snapshot().rows[1].isWrapped && terminal.snapshot().cursorColumn == 1)

    for operation in ["@", "P"] {
        var pending = Terminal(size: .init(columns: 4, rows: 2))
        _ = pending.receive(("ABCD" + csi + operation + "Z").utf8)
        #expect(pending.text(inRow: 0) == "ABCZ")
        #expect(pending.snapshot().cursorRow == 0)
    }
}

@Test func rowEditsRespectTheHiddenSuffixOfANarrowedAlternateBuffer() {
    for (operation, result) in [("@", "A BCDEFG"), ("P", "ACDEFGH"), ("2K", "    EFGH")] {
        var terminal = Terminal(size: .init(columns: 8, rows: 2))
        _ = terminal.receive((csi + "?1049hABCDEFGH").utf8)
        terminal.resize(to: .init(columns: 4, rows: 2))
        _ = terminal.receive((csi + "1;2H" + csi + operation).utf8)
        terminal.resize(to: .init(columns: 8, rows: 2))
        #expect(terminal.text(inRow: 0) == result)
        #expect(terminal.snapshot().cursorColumn == 1)
    }
}

@Test func eraseLineThroughCursorPreservesSoftWrapAndRepairsWideCells() {
    var terminal = Terminal(size: .init(columns: 5, rows: 3))
    _ = terminal.receive(("ABCDE界\u{301}Z" + csi + "2;1H" + csi + "1;33;42m").utf8)
    let before = terminal.snapshot()
    _ = terminal.receive((csi + "1K").utf8)
    let frame = terminal.snapshot()
    var fill = Terminal.Style()
    fill.background = .indexed(2)
    let blank = Terminal.Cell(text: "", width: 1, style: fill)
    #expect(frame.rows[0].generation == before.rows[0].generation)
    #expect(frame.rows[1].isWrapped && frame.rows[1].text == "  Z")
    #expect(frame.rows[1][0] == blank && frame.rows[1][1] == blank)
    #expect(frame.rows[1][2] == before.rows[1][2])
    #expect(frame.cursorRow == 1 && frame.cursorColumn == 0)
    #expect(before.rows[1][0].text == "界\u{301}")
}

@Test func eraseDisplayThroughCursorRetainsHistoryAndErasesPrecedingRows() {
    var terminal = Terminal(size: .init(columns: 5, rows: 3))
    _ = terminal.receive(("HIST\r\nFIRST\r\nABCDE界\u{301}Z" + csi + "3;1H" + csi + "1;33;42m").utf8)
    let before = terminal.snapshot()
    _ = terminal.receive((csi + "1J").utf8)
    let frame = terminal.snapshot()
    var fill = Terminal.Style()
    fill.background = .indexed(2)
    let blank = Terminal.Cell(text: "", width: 1, style: fill)
    #expect(frame.history.count == 1 && frame.history[0].text == "HIST")
    #expect(frame.history[0].generation == before.history[0].generation)
    #expect(frame.rows.map(\.text) == ["", "", "  Z"])
    #expect(frame.rows.allSatisfy { !$0.isWrapped })
    for row in frame.rows[0..<2] { #expect((0..<5).allSatisfy { row[$0] == blank }) }
    #expect(frame.rows[2][0] == blank && frame.rows[2][1] == blank)
    #expect(frame.rows[2][2] == before.rows[2][2])
    #expect(frame.cursorRow == 2 && frame.cursorColumn == 0)

    var wrapped = Terminal(size: .init(columns: 3, rows: 3))
    _ = wrapped.receive(("ABCDEFGHI" + csi + "2;3H" + csi + "1J").utf8)
    let top = wrapped.snapshot()
    #expect(top.rows.map(\.text) == ["", "", "GHI"])
    #expect(!top.rows[2].isWrapped)
}

@Test(arguments: ["1J", "1K"])
func eraseThroughPendingCursorIncludesTheFirstHiddenAlternateCell(_ operation: String) {
    var terminal = Terminal(size: .init(columns: 8, rows: 3))
    _ = terminal.receive((csi + "?1049hABCDEFGH\r\nabcdefgh").utf8)
    terminal.resize(to: .init(columns: 4, rows: 3))
    _ = terminal.receive((csi + "2;4Hx" + csi + operation).utf8)
    #expect(terminal.snapshot().cursorColumn == 4)
    terminal.resize(to: .init(columns: 8, rows: 3))
    #expect(terminal.text(inRow: 0) == (operation == "1J" ? "" : "ABCDEFGH"))
    #expect(terminal.text(inRow: 1) == "     fgh")
}

@Test(arguments: [false, true])
func eraseAboveCompletesAtTheBottomWithoutHistory(pendingWrap: Bool) {
    var terminal = Terminal(size: .init(columns: 3, rows: 3))
    _ = terminal.receive("ABCDEFGHI".utf8)
    if !pendingWrap { _ = terminal.receive((csi + "3;3H").utf8) }
    _ = terminal.receive((csi + "1J").utf8)
    let frame = terminal.snapshot()
    #expect(frame.rows.allSatisfy { $0.text.isEmpty && !$0.isWrapped })
    #expect(frame.cursorRow == 2 && frame.cursorColumn == (pendingWrap ? 3 : 2))
    #expect(frame.history.isEmpty)
    _ = terminal.receive("Z".utf8)
    #expect(terminal.text(inRow: 2) == (pendingWrap ? "Z" : "  Z"))
}

@Test func eraseAboveSeparatesTheNextVisibleRowWithoutChangingHistoryWraps() {
    var terminal = Terminal(size: .init(columns: 3, rows: 3))
    _ = terminal.receive(("ABCDEFGHIJKLMNOPQRSTU" + csi + "1;3H").utf8)
    let before = terminal.snapshot()
    _ = terminal.receive((csi + "1J").utf8)
    let frame = terminal.snapshot()
    #expect(frame.history.map(\.text) == ["ABC", "DEF", "GHI", "JKL"])
    #expect(frame.history.map(\.isWrapped) == [false, true, true, true])
    #expect(frame.history.map(\.generation) == before.history.map(\.generation))
    #expect(frame.rows.map(\.text) == ["", "PQR", "STU"])
    #expect(frame.rows.map(\.isWrapped) == [false, false, true])
    #expect(frame.rows[1].generation != before.rows[1].generation && before.rows[1].isWrapped)
    #expect(frame.cursorRow == 0 && frame.cursorColumn == 2)
}
