import Foundation
import ThrushCore

// The native side of test/identity.mjs. It writes and resizes a terminal through each capture named
// on the command line, and after every step prints the step's reply and then the terminal's
// replay, each after its length as a little-endian UInt32.

struct Capture: Decodable {
    struct Event: Decodable {
        let bytes: Data?
        let resize: Size?
    }

    struct Size: Decodable {
        let columns, rows: Int
    }

    let columns, rows: Int
    let events: [Event]
}

var output: [UInt8] = []
@MainActor func record(_ bytes: [UInt8]) {
    output += withUnsafeBytes(of: UInt32(bytes.count).littleEndian, Array.init)
    output += bytes
}
for path in CommandLine.arguments.dropFirst() {
    let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var terminal = Terminal(size: .init(columns: capture.columns, rows: capture.rows))
    for event in capture.events {
        if let size = event.resize {
            terminal.resize(to: .init(columns: size.columns, rows: size.rows))
            record([])
            record(terminal.replayBytes())
        }
        if let bytes = event.bytes {
            record(terminal.write(bytes))
            record(terminal.replayBytes())
        }
    }
}
FileHandle.standardOutput.write(Data(output))
