import Dispatch
import Thrush
import ThrushFixtures

struct Timing: Encodable {
    let p50Nanoseconds: UInt64
    let p95Nanoseconds: UInt64

    init(_ samples: [UInt64]) {
        let sorted = samples.sorted()
        p50Nanoseconds = sorted[(sorted.count * 50 - 1) / 100]
        p95Nanoseconds = sorted[(sorted.count * 95 - 1) / 100]
    }
}

struct Operation: Encodable {
    let name: String
    let bytesPerCall: Int?
    let timing: Timing
}

struct Replay: Encodable {
    let warmupReplays: Int
    let measuredReplays: Int
    let receivedBytes: Int
    let appliedBytes: Int
    let replyBytes: Int
    let keyBytes: Int
    let receiveMiBPerSecond: Double
    let fixturePeakBytesInOneSecond: Int
    let maximumBurstQueuedBytes: Int
    let queuedBytesAfterDrain: Int
    let burstDrain: Timing
    let operations: [Operation]

    static func measure(_ fixture: FirstBytesFixture) throws -> Replay {
        let warmup = 100
        let measured = 2_000
        let events = fixture.events
        guard let last = events.last else { throw BenchmarkError("The fixture is empty.") }
        let cursorQuery = Array("\u{1B}[6n".utf8)
        guard let queryCheckpoint = events.firstIndex(where: { $0.reply.last == 0x52 }) else {
            throw BenchmarkError("The fixture needs a reference cursor report.")
        }
        let size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)
        let bytesPerReplay = events.reduce(0) { $0 + $1.bytes.count }
        let expectedOutbound = events.flatMap { $0.reply + ($0.up ?? []) }
        var receiveSamples = Array(repeating: [UInt64](), count: events.count)
        var keySamples = Array(repeating: [UInt64](), count: events.count)
        var rowSamples = [UInt64]()
        var querySamples = [UInt64]()
        var drainSamples = [UInt64]()
        var received = 0, applied = 0, replies = 0, keys = 0
        var pendingBytes = 0

        for iteration in 0..<(warmup + measured) {
            let record = iteration >= warmup
            var terminal = Terminal(size: size)
            for (index, event) in events.enumerated() {
                if record { received += event.bytes.count }
                let start = DispatchTime.now().uptimeNanoseconds
                let reply = terminal.receive(event.bytes)
                let receiveTime = DispatchTime.now().uptimeNanoseconds - start
                guard reply == event.reply else { throw BenchmarkError("Reply mismatch at \(event.name).") }
                if record {
                    applied += event.bytes.count
                    replies += reply.count
                    receiveSamples[index].append(receiveTime)
                }
                if let expectedKey = event.up {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let key = terminal.encode(.key(.up))
                    let keyTime = DispatchTime.now().uptimeNanoseconds - start
                    guard key == expectedKey else { throw BenchmarkError("Up mismatch at \(event.name).") }
                    if record {
                        keys += key.count
                        keySamples[index].append(keyTime)
                    }
                }
                let rowStart = DispatchTime.now().uptimeNanoseconds
                let text = terminal.text(inRow: event.row)
                let rowTime = DispatchTime.now().uptimeNanoseconds - rowStart
                guard text == event.text else { throw BenchmarkError("Row mismatch at \(event.name).") }
                if record { rowSamples.append(rowTime) }
                if index == queryCheckpoint {
                    // The fixture's first query spans chunks. Repeat it at the same cursor
                    // position to also measure a complete query in a single receive call.
                    let start = DispatchTime.now().uptimeNanoseconds
                    let report = terminal.receive(cursorQuery)
                    let duration = DispatchTime.now().uptimeNanoseconds - start
                    guard report == event.reply else { throw BenchmarkError("Complete cursor query mismatch.") }
                    if record { querySamples.append(duration) }
                }
            }

            // The whole recording is ready at once. Time its ordered drain separately
            // so per-operation clocks, row checks and percentile bookkeeping stay out.
            var burstTerminal = Terminal(size: size)
            var outbound = [UInt8]()
            outbound.reserveCapacity(expectedOutbound.count)
            pendingBytes = bytesPerReplay
            let start = DispatchTime.now().uptimeNanoseconds
            for event in events {
                outbound.append(contentsOf: burstTerminal.receive(event.bytes))
                pendingBytes -= event.bytes.count
                if event.up != nil {
                    outbound.append(contentsOf: burstTerminal.encode(.key(.up)))
                }
            }
            let drainTime = DispatchTime.now().uptimeNanoseconds - start
            guard pendingBytes == 0, outbound == expectedOutbound,
                  burstTerminal.text(inRow: last.row) == last.text else {
                throw BenchmarkError("The drained burst failed its final checkpoint.")
            }
            if record { drainSamples.append(drainTime) }
        }

        var operations = [Operation]()
        for (index, event) in events.enumerated() {
            operations.append(Operation(name: event.name, bytesPerCall: event.bytes.count,
                                        timing: Timing(receiveSamples[index])))
            if let key = event.up {
                operations.append(Operation(name: "Up after \(event.name)", bytesPerCall: key.count,
                                            timing: Timing(keySamples[index])))
            }
        }
        operations.append(Operation(name: "Read visible row", bytesPerCall: nil, timing: Timing(rowSamples)))
        operations.append(Operation(name: "Complete cursor query", bytesPerCall: cursorQuery.count,
                                    timing: Timing(querySamples)))
        let receiveTime = receiveSamples.reduce(0) { $0 + $1.reduce(0, +) }
        return Replay(
            warmupReplays: warmup, measuredReplays: measured,
            receivedBytes: received, appliedBytes: applied, replyBytes: replies, keyBytes: keys,
            receiveMiBPerSecond: Double(applied) * 1e9 / Double(receiveTime) / 1_048_576,
            fixturePeakBytesInOneSecond: peakBytesInOneSecond(events.map { ($0.offsetMicroseconds, $0.bytes.count) }),
            maximumBurstQueuedBytes: bytesPerReplay, queuedBytesAfterDrain: pendingBytes,
            burstDrain: Timing(drainSamples), operations: operations
        )
    }

}

func peakBytesInOneSecond(_ samples: [(time: Int, bytes: Int)]) -> Int {
    var earliest = 0, bytes = 0, peak = 0
    for sample in samples {
        bytes += sample.bytes
        while sample.time - samples[earliest].time >= 1_000_000 {
            bytes -= samples[earliest].bytes
            earliest += 1
        }
        peak = max(peak, bytes)
    }
    return peak
}
