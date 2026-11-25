import Darwin
import Foundation
import ThrushCore

/// Feeds one comparison workload to ThrushCore and prints pass times and the final screen as one JSON line.
///
/// `scripts/comparison/run.py` runs the same workload through each measured core and compares the results.
/// When the allocation counter library is inserted, each pass also reports how many allocations it made.
struct WorkloadRun: Encodable {
    struct Pass: Encodable {
        let wall: UInt64
        let cpu: UInt64
        let allocations: UInt64?
    }

    struct State: Encodable {
        let cursor: [Int]
        let history: Int
        let alternate: Bool
        let rows: [String]
    }

    let passes: [Pass]
    let state: State

    static let usage = "ThrushBench --workload PATH COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY"

    static func run(arguments: [String]) throws {
        let numbers = arguments.dropFirst(2).compactMap { Int($0) }
        guard arguments.count == 8, numbers.count == 6 else { throw BenchmarkError("Usage: \(usage)") }
        let (columns, rows, chunk, warmups, passes, history) =
            (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5])
        guard history == 1_000 else { throw BenchmarkError("ThrushCore keeps 1000 history rows") }
        let bytes = try [UInt8](Data(contentsOf: URL(filePath: arguments[1])))
        let size = Terminal.Size(columns: columns, rows: rows)
        let allocations = allocationCounter()

        func feed(_ terminal: inout Terminal) {
            let span = bytes.span
            let step = chunk > 0 ? chunk : span.count
            var offset = 0
            while offset < span.count {
                let end = min(offset + step, span.count)
                _ = terminal.receive(span.extracting(offset..<end))
                offset = end
            }
        }

        for _ in 0..<warmups {
            var terminal = Terminal(size: size)
            feed(&terminal)
        }
        var measured: [Pass] = []
        var terminal = Terminal(size: size)
        for _ in 0..<passes {
            terminal = Terminal(size: size)
            let allocated = allocations?()
            let cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            feed(&terminal)
            let wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start
            let used = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpu
            let made = allocations.map { $0() - allocated! }
            measured.append(Pass(wall: wall, cpu: used, allocations: made))
        }
        let snapshot = terminal.snapshot()
        let state = State(cursor: [snapshot.cursorRow, snapshot.cursorColumn], history: snapshot.history.count,
                          alternate: snapshot.isAlternate, rows: snapshot.rows.map(\.text))
        let json = try JSONEncoder().encode(WorkloadRun(passes: measured, state: state))
        FileHandle.standardOutput.write(json + Data([0x0A]))
    }

    /// Finds the counter exported by the comparison's allocation library, when it is inserted.
    private static func allocationCounter() -> (@convention(c) () -> UInt64)? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "comparison_allocations") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> UInt64).self)
    }
}
