import Testing
import ThrushCore

@Test func sgrColonColorsPreserveIndependentRenditions() {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    let bytes = "\u{1b}[38:5:300;48:2::10:20:30;1mA\u{1b}[38:7:1;92;22mB"
        + "\u{1b}[48:2:9:256:257:511;7mC\u{1b}[58;2;2;7;31;101mD"
    for byte in bytes.utf8 { _ = terminal.receive(CollectionOfOne(byte)) }
    let row = terminal.snapshot().rows[0]
    #expect(row[0].style.foreground == .indexed(44))
    #expect(row[0].style.background == .rgb(10, 20, 30))
    #expect(row[0].style.bold)
    #expect(row[1].style.foreground == .indexed(10))
    #expect(row[1].style.background == .rgb(10, 20, 30))
    #expect(!row[1].style.bold)
    #expect(row[2].style.background == .rgb(0, 1, 255))
    #expect(row[2].style.inverse)
    #expect(row[3].style.foreground == .indexed(10))
    #expect(row[3].style.background == .indexed(9))
    #expect(!row[3].style.dim)
}

@Test func sgrColorSeparatorsPreserveTheColorSpaceField() {
    var terminal = Terminal(size: .init(columns: 8, rows: 2))
    let bytes = "\u{1b}[38;2;10;20;30;48;5;201mA\u{1b}[38:2:10:20:30;48;5:42mB"
        + "\u{1b}[38;2::11:22:33;48;2;12:34:56mC\u{1b}[38:5;48:2::;1mD"
    _ = terminal.receive(bytes.utf8)
    let row = terminal.snapshot().rows[0]
    #expect(row[0].style.foreground == .rgb(10, 20, 30))
    #expect(row[0].style.background == .indexed(201))
    #expect(row[1].style.foreground == .rgb(20, 30, 0))
    #expect(row[1].style.background == .indexed(42))
    #expect(row[2].style.foreground == .rgb(11, 22, 33))
    #expect(row[2].style.background == .rgb(12, 34, 56))
    #expect(row[3].style.foreground == .indexed(0))
    #expect(row[3].style.background == .rgb(0, 0, 0))
    #expect(row[3].style.bold)
}

@Test func sgrColorComponentsSaturateAtEverySplit() {
    // Both decimal readers stop at Int32.max, whose low byte is 255. Twenty digits would
    // overflow an Int without the clamp at every digit, and 2^32 would wrap to zero.
    let bytes = Array("\u{1b}[38;5;99999999999999999999;48:2::1:4294967296:2147483647mA".utf8)
    var expected = Terminal.Style()
    expected.foreground = .indexed(255)
    expected.background = .rgb(1, 255, 255)

    for split in 0...bytes.count {
        var terminal = Terminal(size: .init(columns: 8, rows: 2))
        _ = terminal.receive(bytes[..<split])
        let remaining = sequence(state: bytes[split...].makeIterator()) { $0.next() }
        _ = terminal.receive(remaining)
        #expect(terminal.snapshot().rows[0][0].style == expected, "SGR split at byte \(split)")
    }
}

@Test func sgrOperandLimitsAndCancellationMatchAtEverySplit() {
    let csi = "\u{1b}["
    let text = csi + "1;4;38:2::9:8:7;48;5;42mA" + csi + "0;31;7\u{18}B"
        + csi + "3" + String(repeating: ":1", count: 31) + ";4:0;7mC"
        + csi + String(repeating: "3;", count: 31) + "22;0mD" + csi + "mE"
    let bytes = Array(text.utf8)

    var initial = Terminal.Style()
    initial.foreground = .rgb(9, 8, 7)
    initial.background = .indexed(42)
    initial.bold = true
    initial.underline = .single
    var changed = initial
    changed.italic = true
    changed.inverse = true
    changed.underline = .none // The zero in 4:0 is the 32nd colon field.
    var unbold = changed
    unbold.bold = false // Operand 32 is 22. The following reset is past the limit.
    // CAN cancels the reset before B. The empty SGR before E resets all attributes.
    let expected = [initial, initial, changed, unbold, .init()]

    for split in 0...bytes.count {
        var terminal = Terminal(size: .init(columns: 8, rows: 2))
        _ = terminal.receive(bytes[..<split])
        let remaining = sequence(state: bytes[split...].makeIterator()) { $0.next() }
        _ = terminal.receive(remaining)
        let row = terminal.snapshot().rows[0]
        #expect(row.text == "ABCDE")
        #expect(expected.indices.map { row[$0].style } == expected, "SGR split at byte \(split)")
    }
}
