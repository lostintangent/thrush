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
    var whole = Terminal(size: .init(columns: 12, rows: sequences.count * sequences.count + 37))
    var single = whole
    _ = whole.write(stream.span)
    for byte in stream { _ = single.write([byte].span) }

    let cells = { (snapshot: Terminal.Snapshot) in
        snapshot.rows.map { row in (0..<12).map { "\(row[$0].text)/\(row[$0].width)" } }
    }
    #expect(cells(whole.snapshot()) == cells(single.snapshot()))
}
