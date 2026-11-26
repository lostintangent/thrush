import Testing
import ThrushCore

private let esc = "\u{1b}"
private func copy(_ base64: String, selections: String = "c") -> String { "\(esc)]52;\(selections);\(base64)\u{07}" }

private func reply(_ terminal: inout Terminal, _ text: String) -> String {
    String(decoding: terminal.write(Array(text.utf8)), as: UTF8.self)
}

@Test func aCopyReachesTheAppAtEverySplit() {
    // "héllo 🙂" in base64, named by each kind of selection a program uses.
    for selections in ["c", "", "p", "s0"] {
        let bytes = Array(copy("aMOpbGxvIPCfmYI=", selections: selections).utf8)
        for split in 0...bytes.count {
            var terminal = Terminal(size: .init(columns: 8, rows: 2))
            #expect(terminal.write(bytes.prefix(split)).isEmpty)
            #expect(terminal.write(bytes.dropFirst(split)).isEmpty)
            #expect(terminal.copiedText == "héllo 🙂", "\(selections), byte split \(split)")
        }
    }
}

@Test func onlyTextCopies() {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.write((copy("b25l") + copy("dHdv")).utf8)
    #expect(terminal.copiedText == "two")

    // A read goes unanswered, and text that's empty or isn't base64 leaves the last copy waiting.
    #expect(reply(&terminal, copy("?") + copy("") + copy("dH*v") + "\(esc)]52;dHdv\u{07}").isEmpty)
    #expect(terminal.copiedText.take() == "two")
    #expect(terminal.copiedText == nil)
}

@Test func aCopyOverTheControlStringLimitHasNoEffect() {
    // The payload's 2 + 9,999,998 characters fill the limit and decode to 7,499,998 bytes.
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    _ = terminal.write("\(esc)]52;c;".utf8)
    _ = terminal.write(Array(String(repeating: "QUJD", count: 2_499_999).utf8))
    _ = terminal.write("QQ".utf8)
    var overlong = terminal
    _ = terminal.write("\u{07}".utf8)
    #expect(terminal.copiedText?.utf8.count == 7_499_998)
    _ = overlong.write("Q\u{07}".utf8)
    #expect(overlong.copiedText == nil)
}

@Test func capabilitiesReportOnlyHowToCopy() {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    // Only the hex letter is read in either case. A control byte doesn't fold into a digit.
    let answer = reply(&terminal, "\(esc)P+q4d73;544e;5 \r;4D73;\u{14}d73\(esc)\\")
    #expect(answer == "\(esc)P1+r4d73=1B5D35323B25703125733B257032257307\(esc)\\"
        + "\(esc)P1+r4D73=1B5D35323B25703125733B257032257307\(esc)\\")

    // The value is the copy sequence, with the selections and then the text.
    let hex = Array("1B5D35323B25703125733B257032257307".utf8)
    let value = stride(from: 0, to: hex.count, by: 2).map { UInt8(String(decoding: hex[$0...$0 + 1], as: UTF8.self), radix: 16)! }
    #expect(String(decoding: value, as: UTF8.self) == "\(esc)]52;%p1%s;%p2%s\u{07}")
    #expect(reply(&terminal, "\(esc)P+q\(esc)\\" + "\(esc)P+q544e\(esc)\\").isEmpty)
}
