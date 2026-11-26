import Foundation
import ThrushCore

// Runs the same terminal operations as the Wasm module, natively, so their replays can be compared
// byte for byte. Each record on standard input is a letter and its operands, in little-endian:
//   n columns:u16 rows:u16    starts a new terminal
//   w count:u32 bytes         writes bytes
//   s columns:u16 rows:u16    resizes
//   p                         writes the replay to standard output, after its count:u32

let input = [UInt8](FileHandle.standardInput.readDataToEndOfFile())
var output: [UInt8] = []
var position = 0
@MainActor func read(_ count: Int) -> Int {
    defer { position += count }
    return (0..<count).reduce(0) { $0 | Int(input[position + $1]) << (8 * $1) }
}
var terminal = Terminal(size: .init(columns: 80, rows: 24))
while position < input.count {
    let record = input[position]
    position += 1
    switch record {
    case UInt8(ascii: "n"): terminal = Terminal(size: .init(columns: read(2), rows: read(2)))
    case UInt8(ascii: "w"):
        let count = read(4)
        _ = terminal.receive(input[position..<position + count])
        position += count
    case UInt8(ascii: "s"): terminal.resize(to: .init(columns: read(2), rows: read(2)))
    default:
        let replay = terminal.replayBytes()
        output += (0..<4).map { UInt8(truncatingIfNeeded: replay.count >> (8 * $0)) }
        output += replay
    }
}
FileHandle.standardOutput.write(Data(output))
