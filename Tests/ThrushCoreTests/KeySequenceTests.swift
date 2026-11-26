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

@Test func functionKeysAndInsertSendReferenceOrKittyReports() {
    var terminal = Terminal(size: .init(columns: 10, rows: 4))
    func send(_ key: Terminal.Input.Key, _ modifiers: Terminal.Input.Modifiers = []) -> String {
        String(decoding: terminal.encode(.key(key, modifiers: modifiers)), as: UTF8.self)
    }
    let numbered = ["15", "17", "18", "19", "20", "21", "23", "24"].map { "\u{1b}[\($0)~" }
    #expect((1...12).map { send(.function($0)) } == ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS"] + numbered)
    #expect(send(.function(3), .shift) == "\u{1b}[1;2R")
    #expect(send(.function(13)) == "")
    #expect([send(.insert), send(.insert, .alt), send(.insert, .shift), send(.insert, .control)]
            == ["\u{1b}[2~", "\u{1b}[2~", "", ""])

    // Disambiguation keeps F3 from reading as a cursor position report and reports every modifier.
    _ = terminal.receive(Array("\u{1b}[>1u".utf8))
    #expect((1...12).map { send(.function($0)) } == ["\u{1b}[P", "\u{1b}[Q", "\u{1b}[13~", "\u{1b}[S"] + numbered)
    #expect([send(.function(1), .control), send(.function(3), .shift), send(.function(12), .alt)]
            == ["\u{1b}[1;5P", "\u{1b}[13;2~", "\u{1b}[24;3~"])
    #expect([send(.insert, .alt), send(.insert, .shift), send(.pageUp, .alt), send(.pageUp, .shift)]
            == ["\u{1b}[2;3~", "", "\u{1b}[5;3~", ""])
}

/// Programs ask for kitty reports so they can tell Shift-Enter from Enter and Control-I from Tab.
@Test func kittyFlagsDisambiguateKeys() {
    var terminal = Terminal(size: .init(columns: 10, rows: 4))
    func send(_ key: Terminal.Input.Key, _ modifiers: Terminal.Input.Modifiers = []) -> String {
        String(decoding: terminal.encode(.key(key, modifiers: modifiers)), as: UTF8.self)
    }
    let chords: [(Terminal.Input.Key, Terminal.Input.Modifiers)] = [
        (.enter, []), (.enter, .shift), (.enter, .alt), (.tab, []), (.tab, .shift), (.backspace, []),
        (.backspace, .control), (.escape, []), (.escape, .alt), (.character("i"), .control),
        (.character("A"), [.control, .shift]), (.character("a"), .alt), (.character("A"), .shift),
        (.character("é"), .control), (.up, []),
    ]
    _ = terminal.receive(Array("\u{1b}[?1h".utf8))
    #expect(chords.map { send($0, $1) } == [
        "\r", "\r", "\u{1b}\r", "\t", "\u{1b}[Z", "\u{7f}", "\u{8}", "\u{1b}", "\u{1b}\u{1b}", "\t",
        "", "", "A", "", "\u{1b}OA",
    ])
    _ = terminal.receive(Array("\u{1b}[>1u".utf8))
    #expect(chords.map { send($0, $1) } == [
        "\r", "\u{1b}[13;2u", "\u{1b}[13;3u", "\t", "\u{1b}[9;2u", "\u{7f}", "\u{1b}[127;5u",
        "\u{1b}[27u", "\u{1b}[27;3u", "\u{1b}[105;5u", "\u{1b}[97;6u", "\u{1b}[97;3u", "A",
        "\u{1b}[233;5u", "\u{1b}[A",
    ])

    // Alternate keys add the shifted key to chords that hold Shift, and alone they report only those.
    _ = terminal.receive(Array("\u{1b}[=5u".utf8))
    #expect([send(.character("A"), [.control, .shift]), send(.character("a"), [.control, .shift]),
             send(.character("A"), .shift)]
            == ["\u{1b}[97:65;6u", "\u{1b}[97:65;6u", "A"])
    _ = terminal.receive(Array("\u{1b}[=1;3u".utf8))
    #expect([send(.character("A"), [.control, .shift]), send(.character("c"), .control), send(.enter, .shift)]
            == ["\u{1b}[97:65;6u", "\u{3}", "\r"])
}

/// Each screen keeps a stack of up to eight entries. A query answers with the flags in effect, keeping
/// only the two the terminal applies, and either reset empties both stacks.
@Test func kittyFlagsFollowEachScreensStack() {
    var terminal = Terminal(size: .init(columns: 10, rows: 4))
    func reply(_ text: String) -> String {
        String(decoding: terminal.receive(Array(text.utf8)), as: UTF8.self)
    }
    let query = "\u{1b}[?u"
    #expect(reply(query) == "\u{1b}[?0u")
    #expect(reply("\u{1b}[>7u" + query) == "\u{1b}[?5u")
    #expect(reply("\u{1b}[?1049h" + query + "\u{1b}[>1u" + query) == "\u{1b}[?0u\u{1b}[?1u")
    #expect(reply("\u{1b}[?1049l" + query + "\u{1b}[?1049h" + query) == "\u{1b}[?5u\u{1b}[?1u")
    #expect(reply("\u{1b}[=4;2u" + query + "\u{1b}[=1;3u" + query + "\u{1b}[=1;4u" + query)
            == "\u{1b}[?5u\u{1b}[?4u\u{1b}[?4u")
    #expect(reply("\u{1b}[<u" + query + "\u{1b}[=1u" + query + "\u{1b}[<9u" + query)
            == "\u{1b}[?0u\u{1b}[?1u\u{1b}[?0u")

    // A ninth push forgets the oldest entry, and popping past the bottom leaves none.
    let pushes = (1...9).map { "\u{1b}[>\($0 % 2 == 0 ? 4 : 1)u" }.joined()
    #expect(reply(pushes + "\u{1b}[<7u" + query + "\u{1b}[<u" + query) == "\u{1b}[?4u\u{1b}[?0u")

    _ = terminal.receive(Array("\u{1b}[>1u\u{1b}[?1049l".utf8))
    #expect(reply("\u{1b}[!p" + query + "\u{1b}[?1049h" + query) == "\u{1b}[?0u\u{1b}[?0u")
    #expect(reply("\u{1b}[>1u\u{1b}c" + query) == "\u{1b}[?0u")
    #expect(reply("\u{1b}[u") == "")
}
