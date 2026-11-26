import Testing
import ThrushCore

private let esc = "\u{1b}"
private func open(_ uri: String, id: String? = nil) -> String { "\(esc)]8;\(id.map { "id=\($0)" } ?? "");\(uri)\u{07}" }
private let close = "\(esc)]8;;\u{07}"

private func terminal(_ text: String, columns: Int = 12, rows: Int = 3) -> Terminal {
    var terminal = Terminal(size: .init(columns: columns, rows: rows))
    _ = terminal.write(text.utf8)
    return terminal
}

@Test func underlineStylesColorsAndOverlineRoundTripThroughDECRQSS() {
    var terminal = terminal("\(esc)[4:3;58;2;1;2;3;53;31mA\(esc)[21;58;5;9;55mB\(esc)[4:0mC\(esc)[4;59mD")
    let row = terminal.snapshot().rows[0]
    #expect(row[0].style.underline == .curly)
    #expect(row[0].style.underlineColor == .rgb(1, 2, 3))
    #expect(row[0].style.overline)
    #expect(row[1].style.underline == .double)
    #expect(row[1].style.underlineColor == .indexed(9))
    #expect(!row[1].style.overline)
    #expect(row[2].style.underline == .none)
    #expect(row[3].style.underline == .single)
    #expect(row[3].style.underlineColor == .default)

    let replies = terminal.write("\(esc)[4:5;58:2::7:8:9;53m\(esc)P$qm\(esc)\\".utf8)
    #expect(String(decoding: replies, as: UTF8.self) == "\(esc)P1$r0;4:5;53;31;58;2;7;8;9m\(esc)\\")
}

@Test func linksShareANumberOnlyWhenTheyShareAnId() {
    let text = open("https://a.example", id: "x") + "a" + close + "b" + open("https://a.example", id: "x") + "c"
        + open("https://a.example") + "d" + open("https://a.example") + "e" + close + "f"
    let snapshot = terminal(text).snapshot()
    let row = snapshot.rows[0]
    #expect(row[0].style.link != 0)
    #expect(row[0].style.link == row[2].style.link)
    #expect(row[1].style.link == 0)
    #expect(row[3].style.link != row[4].style.link)
    #expect(row[5].style.link == 0)
    #expect(snapshot.link(for: row[2].style)?.id == "x")
    #expect(snapshot.link(for: row[4].style)?.id == nil)
    #expect(snapshot.link(for: row[4].style)?.uri == "https://a.example")
}

@Test func linksOutsideTheLengthLimitsStayPlainText() {
    let uri = "https://a.example/" + String(repeating: "a", count: 2065)
    let id = String(repeating: "i", count: 250)
    let text = open(uri, id: id) + "a" + open(uri + "a") + "b" + open(uri, id: id + "i") + "c"
    let snapshot = terminal(text).snapshot()
    #expect(snapshot.link(for: snapshot.rows[0][0].style)?.uri == uri)
    #expect(snapshot.link(for: snapshot.rows[0][0].style)?.id == id)
    #expect(snapshot.rows[0][1].style.link == 0)
    #expect(snapshot.rows[0][2].style.link == 0)
}

@Test func renditionResetsAndCursorRestoresKeepTheOpenLink() {
    let text = open("https://a.example") + "\(esc)[1;4ma\(esc)[0mb\(esc)7" + close + "\(esc)8c\(esc)7"
        + open("https://b.example") + "\(esc)8d\(esc)[!pe"
    let snapshot = terminal(text).snapshot()
    let row = snapshot.rows[0]
    #expect(snapshot.link(for: row[0].style)?.uri == "https://a.example")
    #expect(row[1].style.link == row[0].style.link)
    #expect(!row[1].style.bold && row[1].style.underline == .none)
    #expect(row[2].style.link == 0)
    #expect(snapshot.link(for: row[3].style)?.uri == "https://b.example")
    #expect(row[4].style.link == 0)
}

@Test func reopeningLinksReusesNumbersThatNoCellHolds() {
    // The first link scrolls into history, then thousands of links each replace the last one's cell.
    var terminal = terminal(open("https://kept.example") + "k" + close + "\r\n\n\n")
    var largest: UInt32 = 0
    for index in 0..<5_000 {
        _ = terminal.write((open("https://\(index).example") + "x\r").utf8)
        largest = max(largest, terminal.snapshot().rows[2][0].style.link)
    }
    let snapshot = terminal.snapshot()
    #expect(largest <= 130)
    #expect(snapshot.link(for: snapshot.rows[2][0].style)?.uri == "https://4999.example")
    #expect(snapshot.link(for: snapshot.history[0][0].style)?.uri == "https://kept.example")
}

@Test func aFullTableTakesNewLinksOnceItsOldOnesAreGone() {
    // Every number is held until the erases let the old links go.
    var terminal = Terminal(size: .init(columns: 80, rows: 24))
    let line = (0..<80).map { open("https://\($0).example") + "x" }.joined() + close + "\r\n"
    for _ in 0..<(65_536 / 80 + 1) { _ = terminal.write(line.utf8) }
    _ = terminal.write("\(esc)[3J\(esc)[2J\(esc)[H".utf8)
    var plain = 0
    for index in 0..<200 {
        _ = terminal.write((open("https://later.example/\(index)") + "y" + close + "\r\n").utf8)
        let snapshot = terminal.snapshot()
        if snapshot.rows[snapshot.cursorRow - 1][0].style.link == 0 { plain += 1 }
    }
    #expect(plain == 0)
}

@Test func replayRestoresEveryLinkAndKeepsIdentifiedLinksWhole() {
    let normal = "\(esc)[4:3;58;5;2;53m" + open("https://a.example", id: "x") + "wrapped link text" + close
        + "\(esc)[0m\r\n" + open("https://b.example") + "one" + close + " " + open("https://b.example") + "two"
        + "\r\n\n\n"
    var original = terminal(normal, columns: 8, rows: 4)
    var resumed = Terminal(size: original.size)
    _ = resumed.write(original.replayBytes())
    expectSameLinks(original.snapshot(), resumed.snapshot())
    let identified = resumed.snapshot().history[0][0].style.link
    #expect(identified != 0 && resumed.snapshot().history[2][0].style.link == identified)

    // The alternate screen replays too, and so does the normal screen behind it.
    _ = original.write(("\(esc)[?1049h" + open("https://c.example", id: "y") + "alt").utf8)
    resumed = Terminal(size: original.size)
    _ = resumed.write(original.replayBytes())
    expectSameLinks(original.snapshot(), resumed.snapshot())
    _ = original.write("\(esc)[?1049lafter".utf8)
    _ = resumed.write("\(esc)[?1049lafter".utf8)
    expectSameLinks(original.snapshot(), resumed.snapshot())
}

private func expectSameLinks(_ before: Terminal.Snapshot, _ after: Terminal.Snapshot) {
    #expect(before.history.count == after.history.count)
    for index in 0..<(before.history.count + before.rows.count) {
        let (old, new) = (before.row(atAbsoluteIndex: index), after.row(atAbsoluteIndex: index))
        for column in 0..<before.size.columns {
            #expect(old[column].text == new[column].text, "row \(index) column \(column)")
            #expect(before.link(for: old[column].style) == after.link(for: new[column].style), "row \(index) column \(column)")
            var (oldStyle, newStyle) = (old[column].style, new[column].style)
            (oldStyle.link, newStyle.link) = (0, 0)
            #expect(oldStyle == newStyle, "row \(index) column \(column)")
        }
    }
}
