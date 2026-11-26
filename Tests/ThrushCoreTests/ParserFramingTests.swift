import Testing
@testable import ThrushCore

/// What the parser reads, with the parameters or payload a function reads.
private enum Read: Equatable {
    case text(String)
    case function(ControlFunction)
    case csi(ControlFunction.CSI, String)
    case osc(ControlFunction.OSC, String)
    case dcs(ControlFunction.DCS, String)
}

/// Reads each chunk as one read, so sequences split where the chunks do.
private func reads(_ chunks: String...) -> [Read] { reads(bytes: chunks.map { Array($0.utf8) }) }

private func reads(bytes chunks: [[UInt8]]) -> [Read] {
    var parser = Parser()
    var result: [Read] = []
    for bytes in chunks {
        let span = bytes.span
        var index = 0
        while let token = parser.next(in: span, from: &index) {
            switch token {
            case .text(.ascii(let run)):
                result.append(.text(String(decoding: bytes[run], as: UTF8.self)))
            case .text(.glyphs(let count)):
                let scalars = (0..<count).map { Unicode.Scalar(Terminal.StoredCell(glyph: parser.glyphs[$0]).scalar)! }
                result.append(.text(String(String.UnicodeScalarView(scalars))))
            case .function(.csi(let function)):
                let parameters = parser.parameters.withBytes(in: span) { header in
                    String(decoding: header.indices.map { header[$0] }, as: UTF8.self)
                }
                result.append(.csi(function, parameters))
            case .function(.osc(let function)): result.append(.osc(function, parser.payload.text))
            case .function(.dcs(let function)): result.append(.dcs(function, parser.payload.text))
            case .function(let function): result.append(.function(function))
            }
        }
    }
    return result
}

@Test func functionsAndParametersSurviveSplitHeaders() {
    #expect(reads("\u{1B}", "[?1:0:", ":3;2", "$", "p", "\u{1B}", "(", "B") == [
        .csi(.requestPrivateMode, "1:0::3;2"),
        .function(.designate(.ascii, slot: 0)),
    ])
    // A whole SGR's header is read from the chunk it arrived in.
    #expect(reads("A\u{1B}[1;31mB\u{1B}[m") == [
        .text("A"), .csi(.graphicRendition, "1;31"), .text("B"), .csi(.graphicRendition, ""),
    ])
}

@Test func parameterLimitsLeaveTheFollowingSequenceAlone() {
    var parameters = Parameters()
    for byte in "0;:0::3;12345678901234;;".utf8 { parameters.append(byte) }
    #expect((0..<parameters.count).map { parameters[$0] } == [0, 0, Int(Int32.max), 0, 0])
    #expect(parameters[0, default: 1] == 1)
    #expect(parameters[2, default: 1] == Int(Int32.max))
    #expect(parameters[99, default: 7] == 7)

    let fields = (1...35).map(String.init).joined(separator: ";")
    #expect(reads("\u{9B}" + fields + "m", "\u{9B}7;2m") == [
        .csi(.graphicRendition, fields),
        .csi(.graphicRendition, "7;2"),
    ])
    var long = Parameters()
    for byte in fields.utf8 { long.append(byte) }
    #expect(long.count == 32)
    #expect((0..<34).map { long[$0] } == Array(1...32) + [0, 0])
}

@Test func textEndsAtEachControl() {
    // A character split across reads, a C1 control, DEL and a byte order mark.
    #expect(reads(bytes: [Array("é\u{85}é\u{7F}e\u{FEFF}é".utf8), [0xC3], [0xA9, 0x0D]]) == [
        .text("é"), .function(.escape(.nextLine)), .text("é"), .text("e"), .text("é"), .text("é"),
        .function(.c0(.carriageReturn)),
    ])
}

@Test func oscStreamsAndEndsOnEscapeBeforeTheSecondSTByte() {
    #expect(reads("\u{1B}]10", ";", "?", "\u{1B}", "\\", "\u{9D}11\u{07}", "\u{9D}4;1;?", "\u{18}", "Z") == [
        .osc(.foregroundColor, "?"), .function(.unsupported),
        .osc(.backgroundColor, ""),
        .function(.unsupported), .text("Z"),
    ])
    #expect(reads("\u{9D}invalid;?\u{07}X", "\u{9D}10;?\u{85}Y") == [
        .text("X"), .function(.escape(.nextLine)), .text("Y"),
    ])
}

@Test func dcsPayloadStreamsC0AndUnicodeUntilTerminatedOrCancelled() {
    #expect(reads("\u{1B}P2:", ":0;4+", "q", "A", "\u{07}", "界", "\u{7F}", "\u{9C}", "Z") == [
        .dcs(.requestCapabilities, "A\u{07}界"), .text("Z"),
    ])
    #expect(reads("\u{1B}[1?2aQ", "\u{1B}[1\u{08}2D", "\u{90}\u{08}4!qX\u{1A}") == [
        .text("Q"), .function(.c0(.backspace)), .csi(.cursorBackward, "12"),
        .function(.unsupported),
    ])
}

@Test func unsupportedStringsDiscardTextAndEndAtTheirTerminators() {
    #expect(reads("\u{9D}777;ignored界", "\u{07}A", "\u{1B}Pzpayload\u{07}", "\u{1B}", "\\B",
                  "\u{9D}999;partial\u{9B}2m", "\u{9D}777;x\u{18}C", "\u{90}qz\u{1A}D",
                  "\u{9D}777;x\u{85}E", "\u{9D}777;x\u{9C}F", "\u{9D}777\u{07}G") == [
        .function(.unsupported), .text("A"),
        .function(.unsupported), .function(.unsupported), .text("B"),
        .function(.unsupported), .csi(.graphicRendition, "2"),
        .function(.unsupported), .text("C"), .function(.unsupported), .text("D"),
        .function(.escape(.nextLine)), .text("E"), .function(.unsupported), .text("F"),
        .function(.unsupported), .text("G"),
    ])
}
