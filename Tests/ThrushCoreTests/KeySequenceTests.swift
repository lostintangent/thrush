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
