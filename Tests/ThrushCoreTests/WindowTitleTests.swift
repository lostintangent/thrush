import Testing
import ThrushCore

@Test func titleRunHonorsTheUTF16LimitAcrossChunks() {
    var pending = Terminal(size: .init(columns: 16, rows: 4))
    _ = pending.write("\u{1B}]2;previous\u{07}\u{1B}]2;".utf8)
    _ = pending.write([UInt8](repeating: 0x61, count: 9_999_997))
    let smile = Array("🙂".utf8)
    _ = pending.write(smile.prefix(2))
    _ = pending.write(smile.suffix(2))
    #expect(pending.title == "previous")

    var exact = pending
    _ = exact.write("z\u{07}".utf8)
    #expect(exact.title.utf16.count == 10_000_000)
    #expect(exact.title.hasSuffix("a🙂z"))

    _ = pending.write("zz\u{07}".utf8)
    #expect(pending.title == "previous")
    _ = pending.write("\u{1B}]0;\u{1B}\\".utf8)
    #expect(pending.title.isEmpty)
}

@Test func printableBytesAfterIncompleteUTF8InATitleResumeAtTheSameByte() {
    var terminal = Terminal(size: .init(columns: 16, rows: 4))
    _ = terminal.write(Array("\u{1B}]2;one ".utf8) + [0xf0, 0x9f])
    _ = terminal.write("two\u{07}screen".utf8)
    #expect(terminal.title == "one two")
    #expect(terminal.text(inRow: 0) == "screen")

    _ = terminal.write("\u{1B}]2;discard this payload\u{18}!".utf8)
    #expect(terminal.title == "one two")
    #expect(terminal.text(inRow: 0) == "screen!")
}
