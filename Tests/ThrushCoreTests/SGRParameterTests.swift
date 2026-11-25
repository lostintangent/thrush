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
