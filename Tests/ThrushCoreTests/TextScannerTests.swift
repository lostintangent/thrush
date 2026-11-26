import Testing
@testable import ThrushCore

@Test(arguments: [0, 1, 7, 8, 15, 16, 17, 31, 32, 33, 64])
func scannerStopsAtTheFirstNonPrintableByte(length: Int) {
    let printable = Array(repeating: UInt8(ascii: "~"), count: length)
    for boundary: UInt8 in [0, 0x1b, 0x1f, 0x7f, 0x80, 0xc2, 0xf0, 0xff] {
        let bytes = [UInt8(ascii: "!")] + printable + [boundary, UInt8(ascii: "x")]
        #expect(TextScanner.endOfASCII(in: bytes.span, from: 1) == 1 + length)
    }
    #expect(TextScanner.endOfASCII(in: printable.span, from: 0) == length)
}

@Test func wholeChunksDecodeAsSingleBytesDo() {
    // Valid sequences of each length, a byte order mark, then overlong forms, surrogates, values past
    // U+10FFFF, invalid lead bytes, a stray continuation and sequences cut short by ASCII.
    let sequences: [[UInt8]] = [
        [0xc3, 0xa9], [0xe7, 0x95, 0x8c], [0xf0, 0x9f, 0x98, 0x80], [0xef, 0xbb, 0xbf],
        [0xc1, 0xbf], [0xe0, 0x9f, 0xbf], [0xf0, 0x8f, 0xbf, 0xbf], [0xed, 0xa0, 0x80],
        [0xf4, 0x90, 0x80, 0x80], [0xf5, 0x80, 0x80, 0x80], [0xf8, 0x84, 0x80, 0x80], [0xff], [0x80],
        [0xe7, 0x95, 0x41], [0xf0, 0x9f, 0x41],
    ]
    var stream: [UInt8] = []
    for first in sequences {
        for second in sequences { stream += first + second + Array("\r\n".utf8) }
    }
    // ASCII between other scalars, from none through more than a block, which ends the text.
    for length in 0...17 {
        stream += [0xc3, 0xa9] + Array(repeating: UInt8(ascii: "x"), count: length) + [0xe7, 0x95, 0x8c, 0x0d, 0x0a]
    }
    // Runs of three-byte scalars, which decode four at a time, then each sequence above in every
    // place of a run of them.
    let wide: [UInt8] = [0xe7, 0x95, 0x8c]
    for length in 1...9 {
        stream += Array(repeating: wide, count: length).joined() + Array("\r\n".utf8)
    }
    for sequence in sequences {
        for place in 0..<4 {
            stream += Array(repeating: wide, count: place).joined() + sequence
                + Array(repeating: wide, count: 4).joined() + Array("\r\n".utf8)
        }
    }
    // Every line fits in two rows, so nothing scrolls away.
    let lines = stream.count { $0 == 0x0a }
    var whole = Terminal(size: .init(columns: 12, rows: 2 * lines + 1))
    var single = whole
    var chunked = whole
    _ = whole.receive(stream.span)
    for byte in stream { _ = single.receive([byte].span) }
    // Odd-sized chunks end inside runs and sequences at every offset.
    for start in stride(from: 0, to: stream.count, by: 17) {
        _ = chunked.receive(Array(stream[start..<min(start + 17, stream.count)]).span)
    }

    let cells = { (snapshot: Terminal.Snapshot) in
        snapshot.rows.map { row in (0..<12).map { "\(row[$0].text)/\(row[$0].width)" } }
    }
    #expect(cells(whole.snapshot()) == cells(single.snapshot()))
    #expect(cells(chunked.snapshot()) == cells(single.snapshot()))
}
