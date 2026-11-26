import Foundation
import Testing
import ThrushCore
@testable import Thrush

@Test func copyIncludesWholeGlyphsAndJoinsOnlySoftWraps() {
    var terminal = Terminal(size: .init(columns: 5, rows: 5))
    _ = terminal.write("abcd翼🐦e\u{301}Z\r\nnext  ".utf8)
    var viewport = Viewport()
    viewport.display(terminal.snapshot())
    #expect(viewport.text(in: .init(anchorRow: 1, anchorColumn: 1, headRow: 1, headColumn: 2)) == "翼🐦")
    #expect(viewport.text(in: .init(anchorRow: 4, anchorColumn: 0, headRow: 0, headColumn: 0))
            == "abcd翼🐦e\u{301}Z\nnext  ")
    viewport.selectLine(row: 1)
    #expect(viewport.selection.map { viewport.text(in: $0) } == "abcd翼🐦e\u{301}Z")
    viewport.selectWord(row: 1, column: 0)
    #expect(viewport.selection.map { viewport.text(in: $0) } == "abcd翼🐦e\u{301}Z")
}

@Test func scrollingAndSelectionStayOnTheSameRowsThroughRingEviction() {
    var terminal = Terminal(size: .init(columns: 20, rows: 4))
    for i in 0..<1_100 { _ = terminal.write("row \(i)\r\n".utf8) }
    var viewport = Viewport()
    viewport.display(terminal.snapshot())
    viewport.scroll(5)
    viewport.selectLine(row: 1)
    let firstLine = viewport.text(in: .init(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 19))
    let selectedLine = viewport.selection.map { viewport.text(in: $0) }
    #expect(firstLine == "row 1092")
    #expect(selectedLine == "row 1093")
    for i in 1_100..<1_112 { _ = terminal.write("row \(i)\r\n".utf8) }
    viewport.display(terminal.snapshot())
    #expect(viewport.offset == 17)
    #expect(viewport.source?.viewport(rowsFromBottom: viewport.offset).rows[0].text == firstLine)
    #expect(viewport.selection.map { viewport.text(in: $0) } == selectedLine)
    viewport.scroll(0)
    #expect(viewport.selection.map { viewport.text(in: $0) } == selectedLine)
    _ = terminal.write("\u{1b}[?1049h".utf8)
    viewport.display(terminal.snapshot())
    #expect(viewport.selection == nil)
    #expect(viewport.historyCount == 0)
}

@Test func reflowPreservesReaderAndCopyAcrossTheNewWraps() {
    var terminal = Terminal(size: .init(columns: 18, rows: 4))
    _ = terminal.write("build log\r\n0128  units/café/界/long-source-path\r\nok\r\nnext\r\ndone\r\n$ ".utf8)
    var viewport = Viewport()
    viewport.display(terminal.snapshot())
    viewport.scroll(viewport.historyCount - 1)
    viewport.selectLine(row: 1)
    let selected = viewport.selection.map { viewport.text(in: $0) }
    #expect(selected == "0128  units/café/界/long-source-path")
    terminal.resize(to: .init(columns: 11, rows: 4))
    viewport.display(terminal.snapshot())
    #expect(viewport.source?.viewport(rowsFromBottom: viewport.offset).rows[0].text == "0128  units")
    #expect(viewport.selection.map { viewport.text(in: $0) } == selected)
}

@MainActor @Test func geometryUsesEachSnappedEdgeAndReportsEachSizeOnce() {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 720, height: 454))
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
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 360, height: 200))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 30, rows: 10))
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    view.display(terminal)
    #expect(!view.reportPointer(.press, button: .left, row: 2, column: 3))
    _ = terminal.write("\u{1b}[?1000;1002;1003;1006h".utf8)
    view.display(terminal)
    #expect(view.reportPointer(.move, button: .none, row: 2, column: 3))
    #expect(view.reportPointer(.move, button: .none, row: 2, column: 3))
    #expect(!view.reportPointer(.press, button: .left, row: 2, column: 3, modifiers: .shift))
    #expect(view.reportPointer(.press, button: .left, row: 1, column: 4))
    #expect(sent == [Array("\u{1b}[<35;4;3M".utf8), Array("\u{1b}[<0;5;2M".utf8)])
}

private func replayScreen(_ lines: [String], columns: Int = 12, rows: Int = 3) -> Terminal.Snapshot {
    var terminal = Terminal(size: .init(columns: columns, rows: rows))
    _ = terminal.write(lines.joined(separator: "\r\n").utf8)
    return terminal.snapshot()
}

@Test func replacingReplayRelocatesWrappedReaderAndBackwardSelection() {
    var reader = Viewport()
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
    var reader = Viewport()
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
    var reader = Viewport()
    reader.display(replayScreen(["one", "repeat", "two", "tag", "repeat", "end", "live"]))
    reader.scroll(reader.historyCount - 1)
    reader.selectLine(row: 0)
    reader.replace(replayScreen(["new", "one", "repeat", "two", "tag", "repeat", "end", "live"]))
    #expect(reader.selection.map { reader.text(in: $0) } == "repeat")
    #expect(reader.source?.viewport(rowsFromBottom: reader.offset).rows[1].text == "two")

    // The retained copy in the new snapshot cannot identify which of two identical
    // occurrences in the old snapshot a person selected.
    reader = Viewport()
    reader.display(replayScreen(["a", "repeat", "b", "a", "repeat", "b", "live"]))
    reader.scroll(reader.historyCount - 1)
    reader.selectLine(row: 0)
    reader.replace(replayScreen(["a", "repeat", "b", "live"]))
    #expect(reader.selection == nil)
}

@Test func replacingReplayRequiresExactBytesBetweenUniqueSelectionEndpoints() {
    var reader = Viewport()
    reader.display(replayScreen(["head", "cafe\u{301}", "tail"]))
    reader.selection = .init(anchorRow: 0, anchorColumn: 0, headRow: 2, headColumn: 3)
    reader.replace(replayScreen(["head", "café", "tail"]))
    #expect(reader.offset == 0)
    #expect(reader.selection == nil)
}

@Test func adoptingNewShellKeepsRepeatedScreenRowsAndDropsUnusedSelection() {
    let size = Terminal.Size(columns: 12, rows: 10)
    var terminal = Terminal(size: size)
    _ = terminal.write("one\r\nsame\r\nend\r\none\r\nsame\r\nend".utf8)
    var selected = Viewport()
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

@Test func linksGoWhereTheirURIsSayWhateverTheirTextShows() throws {
    func link(_ uri: String) -> Terminal.Link? {
        var terminal = Terminal(size: .init(columns: 4, rows: 1))
        _ = terminal.write("\u{1b}]8;;\(uri)\u{1b}\\x".utf8)
        let snapshot = terminal.snapshot()
        return snapshot.link(for: snapshot.rows[0][0].style)
    }
    let docs = try #require(URL(string: "https://example.com/docs"))
    #expect(link("https://example.com/docs")?.destination == .web(docs))
    #expect(link("ssh://devbox")?.openableURL == URL(string: "ssh://devbox"))
    #expect(link("mailto:bird@example.com")?.destination == .app(try #require(URL(string: "mailto:bird@example.com"))))
    let file = try #require(link("file://devbox/tmp/a%20b"))
    #expect(file.destination == .file(path: "/tmp/a b"))
    #expect(file.openableURL == nil && file.copiedText == "/tmp/a b" && file.copyTitle == "Copy Path")
    for uri in ["http:///nowhere", "JavaScript:alert(1)", "data:text/html,hi", "example.com/docs", "file://devbox"] {
        #expect(link(uri)?.destination == .inert, "\(uri)")
    }
    #expect(link("https://example.com/\u{202E}gpj.exe")?.displayedDestination == "https://example.com/%E2%80%AEgpj.exe")
    let long = try #require(link("https://example.com/" + String(repeating: "a", count: 300) + "/end")?.displayedDestination)
    #expect(long.count == 160 && long.hasPrefix("https://example.com/aaa") && long.hasSuffix("aaa/end"))
}

@MainActor @Test func linksHitOnlyTheirOwnCellsAndReadAsOneLinkAcrossRows() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 360, height: 200))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    func open(_ uri: String, id: String = "") -> String { "\u{1b}]8;\(id.isEmpty ? "" : "id=\(id)");\(uri)\u{1b}\\" }
    let close = "\u{1b}]8;;\u{1b}\\"
    var terminal = Terminal(size: .init(columns: 10, rows: 4))
    _ = terminal.write("go \(open("https://example.com/docs", id: "docs"))Security guide\(close).\r\n".utf8)
    _ = terminal.write("\(open("https://a.example"))one\(close) \(open("https://a.example"))two\(close)\r\n".utf8)
    _ = terminal.write("\(open("https://example.com/docs", id: "docs"))more\(close)".utf8)
    view.display(terminal)

    let runs = view.linkRuns()
    let docs = try #require(runs.first?.number)
    #expect(runs.map(\.row) == [0, 1, 2, 2, 3])
    #expect(runs.map(\.columns) == [3..<10, 0..<7, 0..<3, 4..<7, 0..<4])
    #expect(runs.filter { $0.number == docs }.map(\.row) == [0, 1, 3])
    #expect(runs[2].number != runs[3].number)
    #expect(view.linkText(view.linkRuns(of: docs)) == "Security guide more")
    #expect(view.link(row: 1, column: 0)?.link.displayedDestination == "https://example.com/docs")
    #expect(view.rect(of: runs[0]) == view.cellRect(row: 0, column: 3).union(view.cellRect(row: 0, column: 9)))

    func center(_ row: Int, _ column: Int) -> CGPoint {
        let cell = view.cellRect(row: row, column: column)
        return CGPoint(x: cell.midX, y: cell.midY)
    }
    #expect(view.link(at: center(0, 3))?.number == docs)
    #expect(view.link(at: center(0, 2)) == nil)
    #expect(view.link(at: center(1, 7)) == nil)
    let edge = view.cellRect(row: 0, column: 9)
    #expect(view.link(at: CGPoint(x: edge.maxX + 2, y: edge.midY)) == nil)
}

@MainActor @Test func plainURLsOpenLikeLinksAcrossSoftWrapsButNotLineBreaks() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 360, height: 300))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 20, rows: 12))
    _ = terminal.write("see https://example.com/a/long/path ok\r\n".utf8)
    _ = terminal.write("(https://x.y/z). https://ab.c\r\nd\r\n".utf8)
    _ = terminal.write(#"{"u":"https://x.y/q?a=1"} <https://x.y/w>"#.utf8)
    _ = terminal.write("\r\n\u{1b}]8;;https://x.y/sent\u{1b}\\https://x.y/shown\u{1b}]8;;\u{1b}\\ https://en.m/w/A_(b)\r\n".utf8)
    _ = terminal.write("www.x.y ftp://x.y https:// http://".utf8)
    view.display(terminal)

    let links = view.visibleLinks()
    #expect(links.map(\.link.uri) == ["https://example.com/a/long/path", "https://x.y/z", "https://ab.c",
                                      "https://x.y/q?a=1", "https://x.y/w", "https://x.y/sent", "https://en.m/w/A_(b)"])
    #expect(links.map { LinkFinder.isFound($0.number) } == [true, true, true, true, true, false, true])
    let wrapped = links[0]
    #expect(wrapped.runs.map(\.row) == [0, 1] && wrapped.runs.map(\.columns) == [4..<20, 0..<15])
    #expect(view.linkText(wrapped.runs) == "https://example.com/a/long/path")
    #expect(view.link(row: 1, column: 14)?.number == wrapped.number && view.link(row: 1, column: 15) == nil)
    #expect(view.linkRuns(of: wrapped.number) == wrapped.runs)
    #expect(view.linkRuns().map(\.row) == [0, 1, 2, 2, 3, 5, 6, 6, 8, 8, 9])
    #expect(links[1].link.destination == .web(try #require(URL(string: "https://x.y/z"))))
}

@MainActor @Test func aURLAProgramMayHaveCutShortIsNotFound() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 360, height: 300))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 20, rows: 8))
    _ = terminal.write("https://a.example/xy\r\nz\r\n".utf8)
    _ = terminal.write("https://b.ex/c│more\r\nhttps://c.ex/d… ok\r\nhttps://d.ex/e|ok\r\n".utf8)
    _ = terminal.write("“https://e.ex/f” ok\r\nhttps://f.ex/é ok".utf8)
    view.display(terminal)

    #expect(view.visibleLinks().map(\.link.uri) == ["https://e.ex/f", "https://f.ex/é"])
}

@MainActor @Test func aFoundURLReadsWholeAcrossTheViewportsEdgeAndKeepsItsNumberWhileItsLineDoes() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 360, height: 200))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 10, rows: 3))
    _ = terminal.write("https://a.example/xyz\r\n".utf8)
    view.display(terminal)
    let number = try #require(view.link(row: 0, column: 0)?.number)

    _ = terminal.write("one\r\ntwo".utf8)
    view.display(terminal)
    let top = try #require(view.link(row: 0, column: 0))
    #expect(top.number == number && top.link.uri == "https://a.example/xyz")
    #expect(view.linkRuns().map(\.columns) == [0..<1])

    view.setHistoryOffset(2)
    #expect(view.link(row: 0, column: 0)?.number == number)
    #expect(view.linkRuns().map(\.row) == [0, 1, 2])

    _ = terminal.write("\u{1b}[2J\u{1b}[Hhttps://b.example".utf8)
    view.setHistoryOffset(0)
    view.display(terminal)
    let replaced = view.visibleLinks()
    #expect(replaced.map(\.link.uri) == ["https://b.example"] && replaced.first?.number != number)
}
