import Testing
import ThrushCore

// Printed text runs up to the cursor until a control function is performed. REP repeats the last
// character only inside that run, so it shows exactly which bytes end it. Each case runs whole,
// split at every byte and one byte at a time, since a sequence takes a different path in each.

/// Prints A, then `between`, then REP 2, and returns the first row.
private func rowAfterRepeating(_ between: [UInt8]) -> [String] {
    let bytes = Array("A".utf8) + between + Array("\u{1b}[2b".utf8)
    var rows: [String] = []
    for split in 0...bytes.count {
        var terminal = Terminal(size: .init(columns: 10, rows: 2))
        _ = terminal.receive(bytes[..<split])
        _ = terminal.receive(bytes[split...])
        rows.append(terminal.text(inRow: 0))
    }
    var terminal = Terminal(size: .init(columns: 10, rows: 2))
    for byte in bytes { _ = terminal.receive(CollectionOfOne(byte)) }
    rows.append(terminal.text(inRow: 0))
    return rows
}

@Test(arguments: [
    "\u{01}", "\u{07}", "\u{18}", "\u{0e}\u{0f}",
    // Every final byte, whether Thrush performs it or not.
    "\u{1b}[m", "\u{1b}[1;31m", "\u{1b}[>4;1m", "\u{1b}[1 m", "\u{1b}[5y", "\u{1b}7", "\u{1b}Z", "\u{1b}(B",
    // A C1 control Thrush doesn't perform still ends the run.
    "\u{80}",
    // Strings with a number, performed or not, empty, finished or cancelled.
    "\u{1b}]0;title\u{07}", "\u{1b}]0\u{07}", "\u{1b}]9999;x\u{07}", "\u{1b}]\u{07}", "\u{1b}]0;title\u{18}",
    "\u{1b}P$qm\u{1b}\\", "\u{1b}Pzz\u{1b}\\", "\u{1b}P+q\u{9c}",
    // A C1 CSI interrupting a string ends the run even when the sequence it starts is ignored.
    "\u{1b}]0;t\u{9b}1?m", "\u{1b}]9999;t\u{9b}1?m", "\u{1b}P$q\u{9b}1?m", "\u{1b}Pzz\u{9b}1?m",
    // Strings without a function end the run only through ESC \.
    "\u{1b}_apc\u{1b}\\", "\u{1b}]x\u{1b}\\",
])
func functionsEndTheTextRun(_ between: String) {
    #expect(rowAfterRepeating(Array(between.utf8)).allSatisfy { $0 == "A" })
}

@Test(arguments: [
    "", "\u{7f}", "\u{feff}", "\u{9c}",
    // A CSI that turns invalid is ignored.
    "\u{1b}[1?m", "\u{1b}[1;?2m",
    // OSC without a number, and SOS, PM and APC, ended by ST or swallowing BEL.
    "\u{1b}]x\u{07}", "\u{1b}]x\u{9c}", "\u{1b}_apc\u{9c}", "\u{1b}^pm\u{9c}", "\u{1b}Xsos\u{9c}",
    "\u{98}sos\u{9c}", "\u{1b}_apc\u{07}",
])
func ignoredBytesKeepTheTextRun(_ between: String) {
    #expect(rowAfterRepeating(Array(between.utf8)).allSatisfy { $0 == "AAA" })
}

@Test func brokenCharactersKeepTheTextRun() {
    #expect(rowAfterRepeating([0xc3]).allSatisfy { $0 == "AAA" })
    #expect(rowAfterRepeating([0x80]).allSatisfy { $0 == "AAA" })
}

@Test func repeatEndsTheTextRunItRepeats() {
    #expect(rowAfterRepeating(Array("\u{1b}[b".utf8)).allSatisfy { $0 == "AA" })
}

@Test func onlyPlainSGRChangesTheStyle() {
    for sequence in ["\u{1b}[>1m", "\u{1b}[1 m", "\u{1b}[1?m", "\u{9b}>1m"] {
        var terminal = Terminal(size: .init(columns: 4, rows: 1))
        _ = terminal.receive(Array((sequence + "A\u{1b}[1mB").utf8))
        let row = terminal.snapshot().rows[0]
        #expect(!row[0].style.bold && row[1].style.bold, "\(sequence.debugDescription)")
    }
}
