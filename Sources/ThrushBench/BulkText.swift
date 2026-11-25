import CryptoKit
import Dispatch
import Foundation
import ThrushCore

struct BenchmarkGrid: Hashable, Encodable, CustomStringConvertible {
    let columns: Int
    let rows: Int

    var size: Terminal.Size { .init(columns: columns, rows: rows) }
    var description: String { "\(columns)×\(rows)" }

    static let desktop = Self(columns: 80, rows: 24)
    static let portrait = Self(columns: 40, rows: 32)
    static let landscape = Self(columns: 80, rows: 14)
}

struct BulkText: Encodable {
    let grid: BenchmarkGrid
    let inputSHA256: String
    let bytesPerPass: Int
    let chunkBytes: Int
    let measuredPasses: Int
    let receivedBytes: Int
    let appliedBytes: Int
    let receiveMiBPerSecond: Double
    let chunkTime: Timing

    static func measure() throws -> [BulkText] {
        let line = Array(String(repeating: "abcdefghij", count: 8).utf8.prefix(78))
        let bytes = Array(repeating: line + [13, 10], count: 13_108).flatMap { $0 }
        let chunkSize = 4096
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map {
            Array(bytes[$0..<min(bytes.count, $0 + chunkSize)])
        }
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let measured = 5
        return try [BenchmarkGrid.desktop, .portrait, .landscape].map { grid in
            var samples = [UInt64]()
            var received = 0, applied = 0
            for pass in 0...measured {
                var terminal = Terminal(size: grid.size)
                for chunk in chunks {
                    if pass > 0 { received += chunk.count }
                    let start = DispatchTime.now().uptimeNanoseconds
                    let reply = terminal.receive(chunk)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    guard reply.isEmpty else { throw BenchmarkError("Unexpected bulk-text reply at \(grid).") }
                    if pass > 0 {
                        samples.append(elapsed)
                        applied += chunk.count
                    }
                }
                // Pinned xterm validates these same rows, wrap, history and CPR in the fixture generator.
                let snapshot = terminal.snapshot()
                let wrapped = grid.columns < line.count
                let expected = String(decoding: wrapped ? line.dropFirst(grid.columns) : line[...], as: UTF8.self)
                guard snapshot.history.count == 1_000, snapshot.rows[grid.rows - 2].text == expected,
                      snapshot.rows[grid.rows - 2].isWrapped == wrapped, terminal.text(inRow: grid.rows - 1).isEmpty,
                      terminal.receive(Array("\u{1b}[6n".utf8)) == Array("\u{1b}[\(grid.rows);1R".utf8) else {
                    throw BenchmarkError("Bulk-text reference mismatch at \(grid).")
                }
            }
            guard received == bytes.count * measured, applied == received else {
                throw BenchmarkError("Incomplete bulk-text replay at \(grid).")
            }
            return BulkText(grid: grid, inputSHA256: digest, bytesPerPass: bytes.count, chunkBytes: chunkSize,
                            measuredPasses: measured, receivedBytes: received, appliedBytes: applied,
                            receiveMiBPerSecond: mebibytesPerSecond(applied, in: samples.reduce(0, +)),
                            chunkTime: Timing(samples))
        }
    }
}

func mebibytesPerSecond(_ bytes: Int, in nanoseconds: UInt64) -> Double {
    Double(bytes) * 1e9 / Double(nanoseconds) / 1_048_576
}
