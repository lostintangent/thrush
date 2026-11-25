import Testing
@testable import ThrushCore

@Test(arguments: [0, 1, 15, 16, 17, 31, 32, 33, 64])
func scannerStopsAtTheFirstNonPrintableByte(length: Int) {
    let printable = Array(repeating: UInt8(ascii: "~"), count: length)
    for boundary: UInt8 in [0, 0x1b, 0x1f, 0x7f, 0x80, 0xc2, 0xf0, 0xff] {
        let bytes = [UInt8(ascii: "!")] + printable + [boundary, UInt8(ascii: "x")]
        #expect(TextScanner.endOfASCII(in: bytes.span, from: 1) == 1 + length)
    }
    #expect(TextScanner.endOfASCII(in: printable.span, from: 0) == length)
}
