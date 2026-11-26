import Testing
@testable import ThrushCore

// Reference keyboard evaluator in Mac mode, using F1, F12 and Insert.
private let referenceKeyReports: [(Terminal.KeySequence, [String])] = [
    (.ss3(UInt8(ascii: "P")), ["\u{1b}OP", "\u{1b}[1;2P", "\u{1b}[1;3P",
                                "\u{1b}[1;5P", "\u{1b}[1;7P", "\u{1b}[1;8P"]),
    (.numbered(24), ["\u{1b}[24~", "\u{1b}[24;2~", "\u{1b}[24;3~",
                     "\u{1b}[24;5~", "\u{1b}[24;7~", "\u{1b}[24;8~"]),
    (.numbered(2, modifyOn: [], localOn: [.shift, .control]), ["\u{1b}[2~", "", "\u{1b}[2~", "", "", ""]),
]

@Test(arguments: referenceKeyReports, [false, true])
private func letterAndNumberedKeyReports(_ sample: (Terminal.KeySequence, [String]), applicationCursorKeys: Bool) {
    let modifiers: [Terminal.Input.Modifiers] = [[], .shift, .alt, .control, [.alt, .control], [.shift, .alt, .control]]
    let (key, sequences) = sample
    for (chord, sequence) in zip(modifiers, sequences) {
        #expect(key.encode(applicationCursorKeys: applicationCursorKeys, modifiers: chord) == Array(sequence.utf8))
    }
}

/// The reference sends a program scrolling as wheel reports when it asks for the mouse, and
/// as plain Up and Down keys on the alternate screen without reporting.
@Test func scrollingReachesProgramsAsWheelReportsOrArrows() {
    var terminal = Terminal(size: .init(columns: 10, rows: 4))
    func scroll(_ button: Terminal.Input.Pointer.Button, row: Int = 9, column: Int = 99,
                _ modifiers: Terminal.Input.Modifiers = []) -> String {
        let press = Terminal.Input.Pointer(.press, button: button, row: row, column: column, modifiers: modifiers)
        return String(decoding: terminal.encode(.pointer(press)), as: UTF8.self)
    }
    #expect(!terminal.snapshot().programTakesScrolling)
    #expect(scroll(.wheelUp) == "")

    _ = terminal.receive("\u{1b}[?1049h".utf8)
    #expect(terminal.snapshot().programTakesScrolling)
    #expect(scroll(.wheelUp) == "\u{1b}[A")
    #expect(scroll(.wheelDown, [.control, .alt]) == "\u{1b}[B")
    #expect(scroll(.left) == "")
    _ = terminal.receive("\u{1b}[?1h".utf8)
    #expect(scroll(.wheelUp, .control) == "\u{1b}OA")
    #expect(scroll(.wheelDown) == "\u{1b}OB")

    _ = terminal.receive("\u{1b}[?1049l\u{1b}[?1000;1006h".utf8)
    #expect(terminal.snapshot().programTakesScrolling)
    #expect(scroll(.wheelUp) == "")
    #expect(scroll(.wheelUp, row: 1, column: 2) == "\u{1b}[<64;3;2M")
    #expect(scroll(.wheelDown, row: 3, column: 0, .control) == "\u{1b}[<81;1;4M")
}
