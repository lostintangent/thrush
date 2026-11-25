import Testing
@testable import ThrushCore

private extension ControlParameters {
    var mainValues: [Int] { (0..<count).map { self[$0] } }

    var subfieldValues: [[Int?]] {
        (0..<count).map { index in
            (0..<subparameterCount(at: index)).map { self[parameter: index, subparameter: $0] }
        }
    }
}

private enum Frame: Equatable {
    case print(Unicode.Scalar), execute(UInt8), esc(ControlIdentifier)
    case csi(ControlIdentifier, [Int], [[Int?]])
    case osc(Int), dcs(ControlIdentifier, [Int], [[Int?]])
    case put(Unicode.Scalar), end(Bool)

    init(_ action: EscapeParser.Action, scalar: Unicode.Scalar, parameters: borrowing ControlParameters) {
        switch action {
        case .printable: self = .print(scalar)
        case .execute(let byte): self = .execute(byte)
        case .esc(let id): self = .esc(id)
        case .csi(let id): self = .csi(id, parameters.mainValues, parameters.subfieldValues)
        case .oscStart(let id): self = .osc(id)
        case .dcsStart(let id): self = .dcs(id, parameters.mainValues, parameters.subfieldValues)
        case .stringPut(let value): self = .put(value)
        case .stringEnd(let success): self = .end(success)
        }
    }
}

private func frames(_ chunks: String..., discardingPayloads: Bool = false) -> [Frame] {
    var parser = EscapeParser()
    var result: [Frame] = []
    for chunk in chunks {
        for scalar in chunk.unicodeScalars {
            if let action = parser.consume(scalar) {
                result.append(Frame(action, scalar: scalar, parameters: parser.parameters))
                if discardingPayloads {
                    switch action {
                    case .oscStart, .dcsStart: parser.discardStringPayload()
                    default: break
                    }
                }
            }
            if let pending = parser.takePendingAction() { result.append(Frame(pending, scalar: scalar, parameters: parser.parameters)) }
        }
    }
    return result
}

@Test func controlIdentifiersAndParametersSurviveSplitHeaders() {
    let trace = frames("\u{1B}", "[?1:0:", ":3;2", " ", "$", "p", "\u{1B}", "(", "B")
    #expect(trace == [
        .csi(.init(0x70, prefix: 0x3F, intermediate: 0x20, secondIntermediate: 0x24), [1, 2], [[0, nil, 3], []]),
        .esc(.init(0x42, intermediate: 0x28)),
    ])
}

@Test func parameterLimitsPreserveTheStoredPrefixAndFollowingSequence() {
    var parameters = ControlParameters()
    for byte in "0;:0::3;12345678901234;;".utf8 { parameters.append(byte) }
    #expect(parameters.mainValues == [0, 0, Int(Int32.max), 0, 0])
    #expect(parameters[0, default: 1] == 1)
    #expect(parameters[2, default: 1] == Int(Int32.max))
    #expect(parameters[99, default: 7] == 7)
    #expect(parameters.subfieldValues[1] == [0, nil, 3])

    let fields = (1...35).map(String.init).joined(separator: ";")
    let subfields = String(repeating: ":0", count: 32)
    #expect(frames("\u{9B}" + fields + "m", "\u{9B}1" + subfields + ":9;7:6;2m") == [
        .csi(.init(0x6D), Array(1...32), Array(repeating: [], count: 32)),
        .csi(.init(0x6D), [1, 7, 2], [Array(repeating: 0, count: 32), [], []]),
    ])
}

@Test func oscStreamsAndEndsOnEscapeBeforeTheSecondSTByte() {
    #expect(frames("\u{1B}]10", ";", "?", "\u{1B}", "\\", "\u{9D}11\u{07}", "\u{9D}4;1;?", "\u{18}", "Z") == [
        .osc(10), .put("?"), .end(true), .esc(.init(0x5C)),
        .osc(11), .end(true),
        .osc(4), .put("1"), .put(";"), .put("?"), .end(false), .print("Z"),
    ])
    #expect(frames("\u{9D}invalid;?\u{07}X", "\u{9D}10;?\u{85}Y") == [
        .print("X"), .osc(10), .put("?"), .end(false), .execute(0x85), .print("Y"),
    ])
}

@Test func dcsPayloadStreamsC0AndUnicodeUntilTerminatedOrCancelled() {
    #expect(frames("\u{1B}P>2:", ":0;4+", "q", "A", "\u{07}", "界", "\u{7F}", "\u{9C}", "Z") == [
        .dcs(.init(0x71, prefix: 0x3E, intermediate: 0x2B), [2, 4], [[nil, 0], []]),
        .put("A"), .put("\u{07}"), .put("界"), .end(true), .print("Z"),
    ])
    #expect(frames("\u{1B}[1?2aQ", "\u{1B}[1\u{08}2D", "\u{90}\u{08}4!qX\u{1A}") == [
        .print("Q"), .execute(0x08), .csi(.init(0x44), [12], [[]]),
        .dcs(.init(0x71, intermediate: 0x21), [4], [[]]), .put("X"), .end(false),
    ])
}

@Test func unhandledStringsDiscardTextAndRetainTheirTerminators() {
    #expect(frames("\u{9D}777;ignored界", "\u{07}A", "\u{1B}P+qpayload\u{07}", "\u{1B}", "\\B",
                   "\u{9D}999;partial\u{9B}2m", "\u{9D}777;x\u{18}C", "\u{90}qz\u{1A}D",
                   "\u{9D}777;x\u{85}E", "\u{9D}777;x\u{9C}F", "\u{9D}777\u{07}G",
                   discardingPayloads: true) == [
        .osc(777), .print("A"),
        .dcs(.init(0x71, intermediate: 0x2B), [0], [[]]), .esc(.init(0x5C)), .print("B"),
        .osc(999), .csi(.init(0x6D), [2], [[]]),
        .osc(777), .print("C"), .dcs(.init(0x71), [0], [[]]), .print("D"),
        .osc(777), .execute(0x85), .print("E"), .osc(777), .print("F"), .osc(777), .print("G"),
    ])
}
