import Testing
import ThrushCore
@testable import Thrush

@Test func copyIncludesWholeGlyphsAndJoinsOnlySoftWraps() {
    var terminal = Terminal(size: .init(columns: 5, rows: 5))
    _ = terminal.receive("abcd翼🐦e\u{301}Z\r\nnext  ".utf8)
    var transcript = TerminalTranscript()
    transcript.display(terminal.snapshot())
    #expect(transcript.text(in: .init(anchorRow: 1, anchorColumn: 1, headRow: 1, headColumn: 2)) == "翼🐦")
    #expect(transcript.text(in: .init(anchorRow: 4, anchorColumn: 0, headRow: 0, headColumn: 0))
            == "abcd翼🐦e\u{301}Z\nnext  ")
    transcript.selectLine(row: 1)
    #expect(transcript.selection.map { transcript.text(in: $0) } == "abcd翼🐦e\u{301}Z")
    transcript.selectWord(row: 1, column: 0)
    #expect(transcript.selection.map { transcript.text(in: $0) } == "abcd翼🐦e\u{301}Z")
}

@Test func scrollingAndSelectionStayOnTheSameRowsThroughRingEviction() {
    var terminal = Terminal(size: .init(columns: 20, rows: 4))
    for i in 0..<1_100 { _ = terminal.receive("row \(i)\r\n".utf8) }
    var transcript = TerminalTranscript()
    transcript.display(terminal.snapshot())
    transcript.scroll(5)
    transcript.selectLine(row: 1)
    let firstLine = transcript.text(in: .init(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 19))
    let selectedLine = transcript.selection.map { transcript.text(in: $0) }
    #expect(firstLine == "row 1092")
    #expect(selectedLine == "row 1093")
    for i in 1_100..<1_112 { _ = terminal.receive("row \(i)\r\n".utf8) }
    transcript.display(terminal.snapshot())
    #expect(transcript.offset == 17)
    #expect(transcript.source?.viewport(rowsFromBottom: transcript.offset).rows[0].text == firstLine)
    #expect(transcript.selection.map { transcript.text(in: $0) } == selectedLine)
    transcript.scroll(0)
    #expect(transcript.selection.map { transcript.text(in: $0) } == selectedLine)
    _ = terminal.receive("\u{1b}[?1049h".utf8)
    transcript.display(terminal.snapshot())
    #expect(transcript.selection == nil)
    #expect(transcript.historyCount == 0)
}

@Test func reflowPreservesReaderAndCopyAcrossTheNewWraps() {
    var terminal = Terminal(size: .init(columns: 18, rows: 4))
    _ = terminal.receive("build log\r\n0128  units/café/界/long-source-path\r\nok\r\nnext\r\ndone\r\n$ ".utf8)
    var transcript = TerminalTranscript()
    transcript.display(terminal.snapshot())
    transcript.scroll(transcript.historyCount - 1)
    transcript.selectLine(row: 1)
    let selected = transcript.selection.map { transcript.text(in: $0) }
    #expect(selected == "0128  units/café/界/long-source-path")
    terminal.resize(to: .init(columns: 11, rows: 4))
    transcript.display(terminal.snapshot())
    #expect(transcript.source?.viewport(rowsFromBottom: transcript.offset).rows[0].text == "0128  units")
    #expect(transcript.selection.map { transcript.text(in: $0) } == selected)
}

@MainActor @Test func geometryUsesEachSnappedEdgeAndReportsEachSizeOnce() {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 720, height: 454))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var sizes: [Terminal.Size] = []
    view.onGridSizeChange = { sizes.append($0) }
    #if os(macOS)
    view.layout()
    view.layout()
    #else
    view.layoutSubviews()
    view.layoutSubviews()
    #endif
    guard let grid = view.gridSize else { Issue.record("No native grid after layout."); return }
    view.display(Terminal(size: grid))
    for i in 0..<grid.columns {
        let rect = view.cellRect(row: 1, column: i)
        #expect(view.cell(at: .init(x: rect.minX, y: rect.midY))?.column == i)
        #expect(view.cell(at: .init(x: rect.maxX - 0.01, y: rect.midY))?.column == i)
    }
    view.frame.size.width -= 32
    #if os(macOS)
    view.layout()
    view.layout()
    #else
    view.layoutSubviews()
    view.layoutSubviews()
    #endif
    #expect(sizes.count >= 1)
    #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 != $1 })
}

@MainActor @Test func pointerTrackingAndLocalOverrideFollowTheDisplayedModes() {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 360, height: 200))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 30, rows: 10))
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    view.display(terminal)
    #expect(!view.reportPointer(.press, button: .left, row: 2, column: 3))
    _ = terminal.receive("\u{1b}[?1000;1002;1003;1006h".utf8)
    view.display(terminal)
    #expect(view.reportPointer(.move, button: .none, row: 2, column: 3))
    #expect(view.reportPointer(.move, button: .none, row: 2, column: 3))
    #expect(!view.reportPointer(.press, button: .left, row: 2, column: 3, modifiers: .shift))
    #expect(view.reportPointer(.press, button: .left, row: 1, column: 4))
    #expect(sent == [Array("\u{1b}[<35;4;3M".utf8), Array("\u{1b}[<0;5;2M".utf8)])
}

private func replayScreen(_ lines: [String], columns: Int = 12, rows: Int = 3) -> Terminal.Snapshot {
    var terminal = Terminal(size: .init(columns: columns, rows: rows))
    _ = terminal.receive(lines.joined(separator: "\r\n").utf8)
    return terminal.snapshot()
}

@Test func replacingReplayRelocatesWrappedReaderAndBackwardSelection() {
    var reader = TerminalTranscript()
    reader.display(replayScreen(["old", "0123456789abcdef", "after", "tail", "extra", "$"], columns: 8))
    reader.scroll(reader.historyCount - 2)
    reader.selection = .init(anchorRow: 0, anchorColumn: 3, headRow: 0, headColumn: 0)
    #expect(reader.selection.map { reader.text(in: $0) } == "89ab")

    reader.replace(replayScreen(["new", "old", "0123456789abcdef", "after", "tail", "extra", "$"], columns: 4))
    #expect(reader.source?.viewport(rowsFromBottom: reader.offset).rows.first?.text == "89ab")
    #expect(reader.selection == .init(anchorRow: 0, anchorColumn: 3, headRow: 0, headColumn: 0))
    #expect(reader.selection.map { reader.text(in: $0) } == "89ab")
}

@Test func replacingReplayFindsNearestSurvivingNeighborOrOldestRow() {
    var reader = TerminalTranscript()
    reader.display(replayScreen(["apple", "birch", "cedar", "elm", "fern", "ivy"]))
    reader.scroll(reader.historyCount - 2)
    reader.selectLine(row: 0)
    reader.replace(replayScreen(["first", "elm", "spruce", "birch", "end"]))
    #expect(reader.source?.viewport(rowsFromBottom: reader.offset).rows.first?.text == "elm")
    #expect(reader.selection == nil)

    reader.replace(replayScreen(["from scratch", "row two", "three", "four", "five"]))
    #expect(reader.offset == reader.historyCount)
    #expect(reader.source?.viewport(rowsFromBottom: reader.offset).rows.first?.text == "from scratch")
}

@Test func replacingReplayUsesUniqueNeighborsAndRejectsAmbiguousEndpoints() {
    var reader = TerminalTranscript()
    reader.display(replayScreen(["one", "repeat", "two", "tag", "repeat", "end", "live"]))
    reader.scroll(reader.historyCount - 1)
    reader.selectLine(row: 0)
    reader.replace(replayScreen(["new", "one", "repeat", "two", "tag", "repeat", "end", "live"]))
    #expect(reader.selection.map { reader.text(in: $0) } == "repeat")
    #expect(reader.source?.viewport(rowsFromBottom: reader.offset).rows[1].text == "two")

    // The retained copy in the new snapshot cannot identify which of two identical
    // occurrences in the old snapshot a person selected.
    reader = TerminalTranscript()
    reader.display(replayScreen(["a", "repeat", "b", "a", "repeat", "b", "live"]))
    reader.scroll(reader.historyCount - 1)
    reader.selectLine(row: 0)
    reader.replace(replayScreen(["a", "repeat", "b", "live"]))
    #expect(reader.selection == nil)
}

@Test func replacingReplayRequiresExactBytesBetweenUniqueSelectionEndpoints() {
    var reader = TerminalTranscript()
    reader.display(replayScreen(["head", "cafe\u{301}", "tail"]))
    reader.selection = .init(anchorRow: 0, anchorColumn: 0, headRow: 2, headColumn: 3)
    reader.replace(replayScreen(["head", "café", "tail"]))
    #expect(reader.offset == 0)
    #expect(reader.selection == nil)
}

@Test func adoptingNewShellKeepsRepeatedScreenRowsAndDropsUnusedSelection() {
    let size = Terminal.Size(columns: 12, rows: 10)
    var terminal = Terminal(size: size)
    _ = terminal.receive("one\r\nsame\r\nend\r\none\r\nsame\r\nend".utf8)
    var selected = TerminalTranscript()
    selected.display(terminal.snapshot())
    selected.selection = .init(anchorRow: 4, anchorColumn: 0, headRow: 4, headColumn: 3)
    var padding = selected
    padding.selection = .init(anchorRow: 9, anchorColumn: 0, headRow: 9, headColumn: 1)
    terminal.startNewShell(at: size)
    let screen = terminal.snapshot()
    selected.replace(screen, archivingMainScreen: true)
    padding.replace(screen, archivingMainScreen: true)
    selected.scroll(selected.historyCount)
    #expect(selected.selection == .init(anchorRow: 4, anchorColumn: 0, headRow: 4, headColumn: 3))
    #expect(padding.selection == nil)
}
