import Testing
@testable import ThrushCore

// Parameters keeps a header's bytes and compacts them past 1 KiB. These tests read each header the way
// the parser used to, parsing every byte into fixed fields as it arrived, and expect every split and
// every compaction to read the same.

/// The reading of a header under the 32-parameter and 32-subparameter limits, with saturated values.
private struct Reading: Equatable {
    var parameters: [Int32] = [0]
    var subparameters: [[Int32?]] = [[]]
    var totalSubparameters = 0
    /// Bytes past a limit change nothing until the next semicolon, or ever after the 32nd one.
    var ignoresDigits = false
    var ignoresRest = false

    init(_ header: some Sequence<UInt8>) {
        for byte in header where !ignoresRest {
            switch byte {
            case Parameters.semicolon:
                guard parameters.count < Parameters.limit else { ignoresRest = true; continue }
                parameters.append(0)
                subparameters.append([])
                ignoresDigits = false
            case Parameters.colon:
                guard totalSubparameters < Parameters.limit else { ignoresDigits = true; continue }
                subparameters[subparameters.count - 1].append(nil)
                totalSubparameters += 1
                ignoresDigits = false
            default:
                guard !ignoresDigits else { continue }
                let digit = Int(byte - UInt8(ascii: "0"))
                let last = subparameters.count - 1
                if let ordinal = subparameters[last].indices.last {
                    subparameters[last][ordinal] = Int32(clamping: Int(subparameters[last][ordinal] ?? 0) * 10 + digit)
                } else {
                    parameters[last] = Int32(clamping: Int(parameters[last]) * 10 + digit)
                }
            }
        }
    }

    /// The same reading written without anything the limits ignore, short enough to store whole.
    var header: String {
        zip(parameters, subparameters).map { value, subparameters in
            String(value) + subparameters.map { ":" + ($0.map { String($0) } ?? "") }.joined()
        }.joined(separator: ";")
    }
}

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Mostly zeros and nines, so leading zeros and saturation come up often, with colons and semicolons.
private func randomHeader(length: Int, using random: inout SplitMix) -> [UInt8] {
    let alphabet = Array("0000123999;;;:::".utf8)
    return (0..<length).map { _ in alphabet.randomElement(using: &random)! }
}

/// Appends each piece as a run inside a read, with the final byte after it when `followed`, so short
/// runs take both the block copy and the byte loop.
private func parameters(_ pieces: some Sequence<ArraySlice<UInt8>>, byteAtATime: Bool = false, followed: Bool = true) -> Parameters {
    var parameters = Parameters()
    for piece in pieces {
        if byteAtATime {
            for byte in piece { parameters.append(byte) }
        } else {
            let read = Array("\u{1B}[".utf8) + piece + (followed ? Array("m\u{1B}[0mhello world".utf8) : [])
            parameters.append(2..<2 + piece.count, of: read.span)
        }
    }
    return parameters
}

private func sgrStyle(_ parameters: Parameters) -> Terminal.Style {
    var parameters = parameters
    var style = Terminal.Style()
    style.applySGR(&parameters)
    return style
}

/// Expects stored parameters to read as the reference reads the bytes that arrived.
private func expectReading(_ stored: Parameters, of header: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) {
    var stored = stored
    let reference = Reading(header)
    let described = Array(stored.description.utf8)
    #expect(Reading(described) == reference, "compacted \(described.count) bytes", sourceLocation: sourceLocation)
    #expect(stored.count == reference.parameters.count, sourceLocation: sourceLocation)
    let values = (0...Parameters.limit + 1).map { stored[$0, default: -1] }
    let expected = (0...Parameters.limit + 1).map { index in
        index < reference.parameters.count && reference.parameters[index] != 0 ? Int(reference.parameters[index]) : -1
    }
    #expect(values == expected, sourceLocation: sourceLocation)
    #expect(sgrStyle(stored) == sgrStyle(parameters([ArraySlice(reference.header.utf8)])), sourceLocation: sourceLocation)
}

@Test func parametersReadAsTheyArrivedAtEverySplit() {
    var random = SplitMix(state: 1)
    var headers = (0..<400).map { _ in randomHeader(length: Int.random(in: 0...48, using: &random), using: &random) }
    headers += ["", ";", ":", "0", "00:00", "38:2::255:128:0;1", "2147483647;2147483648;99999999999"].map { Array($0.utf8) }
    for header in headers {
        for split in 0...header.count {
            expectReading(parameters([header[..<split], header[split...]]), of: header)
            expectReading(parameters([header[..<split], header[split...]], followed: false), of: header)
        }
        expectReading(parameters([header[...]], byteAtATime: true), of: header)
    }
}

@Test func hostileHeadersCompactWithoutChangingTheReading() {
    func repeated(_ text: String, _ count: Int) -> [UInt8] { Array(String(repeating: text, count: count).utf8) }
    var random = SplitMix(state: 2)
    var headers: [[UInt8]] = [
        repeated("0", 5000) + Array("5".utf8),
        repeated("0", 3000),
        Array("7".utf8) + repeated("3", 3000),
        repeated("12345678901234567890;", 60),
        repeated("1:", 3000),
        Array("1".utf8) + repeated(":0", 40) + Array(";2:3;4".utf8) + repeated(":", 2000) + Array("5;6".utf8),
        repeated(";", 3000) + Array("8".utf8),
        repeated("9", 1023) + Array(";4".utf8),
        repeated(":", 1500) + repeated("9", 1500),
        // Each field keeps as many bytes as compaction allows.
        repeated("01234567890123:01234567890123:::;", 40),
    ]
    headers += (0..<40).map { _ in randomHeader(length: Int.random(in: 900...4000, using: &random), using: &random) }
    for header in headers {
        expectReading(parameters([header[...]]), of: header)
        expectReading(parameters([header[...]], byteAtATime: true), of: header)
        var pieces: [ArraySlice<UInt8>] = []
        var start = 0
        while start < header.count {
            let end = min(header.count, start + Int.random(in: 1...400, using: &random))
            pieces.append(header[start..<end])
            start = end
        }
        expectReading(parameters(pieces), of: header)
    }
}
