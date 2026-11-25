import Dispatch
import ThrushCore
import ThrushFixtures

struct ResizeTiming: Encodable {
    let from: BenchmarkGrid
    let requested: BenchmarkGrid
    let to: BenchmarkGrid
    let alternate: Bool
    let historyRowsBefore: Int
    let normalHistoryRowsBefore: Int
    let timing: Timing
    let withinDisplayInterval: Bool
}

struct HeadlessReplay: Encodable {
    static let displayIntervalNanoseconds: UInt64 = 1_000_000_000 / 120

    let name: String
    let fixtureSHA256: String
    let requestedGrid: BenchmarkGrid
    let initialGrid: BenchmarkGrid
    let measuredReplays: Int
    let referenceCheckpointsPerReplay: Int
    let receivedBytes: Int
    let appliedBytes: Int
    let replyBytes: Int
    let encodedInputBytes: Int
    let receiveMiBPerSecond: Double
    let receiveSamples = ReceiveRate.samples
    let receiveReplaysPerSample: Int
    let chunkTime: Timing
    let fixturePeakBytesInOneSecond: Int
    let fixturePeakMultiple: Double
    let meetsTwiceRecordedPeak: Bool
    let queueByteLimit = BurstQueue.byteLimit
    let queueSlotLimit = BurstQueue.slotLimit
    let maximumQueuedBytes: Int
    let maximumQueuedSlots: Int
    let queuedBytesAfterDrain: Int
    let burstDrain: Timing
    let resizes: [ResizeTiming]
    let paletteChangesPerReplay: Int
    let paletteChangeTime: Timing?
    let input: [Operation]

    static func measure(_ fixture: ReplayFixture, named name: String) throws -> HeadlessReplay {
        let measured = 25
        let bytesPerReplay = fixture.events.reduce(0) { $0 + $1.bytes.count }
        let repliesPerReplay = fixture.events.reduce(0) { $0 + $1.reply.count }
        let paletteChanges = fixture.events.filter { $0.palette != nil }.count
        let checkpoints = fixture.events.filter { $0.checkpoint != nil }.count
        guard bytesPerReplay > 0, checkpoints > 0 else { throw BenchmarkError("Empty replay \(name).") }

        // Use the same bounded feeder for reference verification and timings. Full-grid
        // comparisons run once before measurement and can walk 1,000 rows of history.
        let reference = try run(fixture, checkReference: true)
        let runs = try (0..<measured).map { _ in try run(fixture, checkReference: false) }
        let samples = runs.flatMap(\.chunks)
        for run in runs {
            guard run.appliedBytes == bytesPerReplay, run.receivedBytes == bytesPerReplay,
                  run.replyBytes == repliesPerReplay, run.encodedInputBytes == reference.encodedInputBytes,
                  run.paletteChangeTimes.count == paletteChanges,
                  run.maximumQueuedBytes <= BurstQueue.byteLimit, run.maximumQueuedSlots <= BurstQueue.slotLimit,
                  run.queuedBytesAfterDrain == 0 else { throw BenchmarkError("Incomplete replay \(name).") }
        }

        let resizes = reference.resizes.enumerated().map { index, measurement in
            let timing = Timing(runs.map { $0.resizes[index].duration })
            return ResizeTiming(from: measurement.from, requested: measurement.requested,
                                to: measurement.to, alternate: measurement.alternate,
                                historyRowsBefore: measurement.historyRows,
                                normalHistoryRowsBefore: measurement.normalHistoryRows, timing: timing,
                                withinDisplayInterval: timing.p95Nanoseconds <= displayIntervalNanoseconds)
        }
        let input = reference.keys.enumerated().map { index, observation in
            Operation(name: observation.name, bytesPerCall: observation.bytes,
                      timing: Timing(runs.map { $0.keys[index].duration }))
        }
        let applied = runs.reduce(0) { $0 + $1.appliedBytes }
        let paletteTimes = runs.flatMap(\.paletteChangeTimes)
        let receive = ReceiveRate(size: .init(columns: fixture.columns, rows: fixture.rows), spans: spans(of: fixture))
        let rate = receive.mebibytesPerSecond
        let peak = peakBytesInOneSecond(fixture.events.map { ($0.offsetMicroseconds, $0.bytes.count) })
        let multiple = rate * 1_048_576 / Double(peak)
        return HeadlessReplay(
            name: name, fixtureSHA256: fixture.sha256,
            requestedGrid: .init(columns: fixture.columns, rows: fixture.rows), initialGrid: reference.initialGrid,
            measuredReplays: measured,
            referenceCheckpointsPerReplay: checkpoints,
            receivedBytes: runs.reduce(0) { $0 + $1.receivedBytes }, appliedBytes: applied,
            replyBytes: runs.reduce(0) { $0 + $1.replyBytes },
            encodedInputBytes: runs.reduce(0) { $0 + $1.encodedInputBytes },
            receiveMiBPerSecond: rate, receiveReplaysPerSample: receive.replaysPerSample,
            chunkTime: Timing(samples), fixturePeakBytesInOneSecond: peak,
            fixturePeakMultiple: multiple, meetsTwiceRecordedPeak: multiple >= 2,
            maximumQueuedBytes: runs.map(\.maximumQueuedBytes).max()!,
            maximumQueuedSlots: runs.map(\.maximumQueuedSlots).max()!,
            queuedBytesAfterDrain: reference.queuedBytesAfterDrain, burstDrain: Timing(runs.map(\.drain)),
            resizes: resizes, paletteChangesPerReplay: paletteChanges,
            paletteChangeTime: paletteTimes.isEmpty ? nil : Timing(paletteTimes), input: input
        )
    }

    private struct Pass {
        let initialGrid: BenchmarkGrid
        var receivedBytes = 0, appliedBytes = 0, replyBytes = 0, encodedInputBytes = 0
        var maximumQueuedBytes = 0, maximumQueuedSlots = 0, queuedBytesAfterDrain = 0
        var drain: UInt64 = 0
        var chunks = [UInt64]()
        var paletteChangeTimes = [UInt64]()
        var resizes: [(from: BenchmarkGrid, requested: BenchmarkGrid, to: BenchmarkGrid, alternate: Bool,
                       historyRows: Int, normalHistoryRows: Int, duration: UInt64)] = []
        var keys: [(name: String, bytes: Int, duration: UInt64)] = []
    }

    private static func run(_ fixture: ReplayFixture, checkReference: Bool) throws -> Pass {
        var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
        let titleFixture = checkReference && fixture.name == "codex-session" ? try WindowTitleFixture.load() : nil
        if let recording = titleFixture?.codex {
            guard recording.fixtureSHA256 == fixture.sha256, !recording.checkpoints.isEmpty else {
                throw BenchmarkError("Missing or mismatched window-title expectations for this Codex recording.")
            }
        }
        var titles = (titleFixture?.codex.checkpoints ?? [])[...]
        var result = Pass(initialGrid: .init(columns: terminal.size.columns, rows: terminal.size.rows))
        var queue = BurstQueue()
        var reply = [UInt8]()
        let start = DispatchTime.now().uptimeNanoseconds
        while queue.fill(from: fixture.events) {
            result.receivedBytes += queue.bytes
            result.maximumQueuedBytes = max(result.maximumQueuedBytes, queue.bytes)
            result.maximumQueuedSlots = max(result.maximumQueuedSlots, queue.items.count)
            var pending = queue.bytes
            for item in queue.items {
                let event = fixture.events[item.event]
                if item.range.lowerBound == 0 { event.applyReady(to: &terminal) }
                if item.range.lowerBound == 0, let palette = event.palette {
                    let start = DispatchTime.now().uptimeNanoseconds
                    terminal.palette = palette
                    result.paletteChangeTimes.append(DispatchTime.now().uptimeNanoseconds - start)
                }
                if item.range.lowerBound == 0, let resize = event.resize {
                    guard event.checkpoint != nil else { throw BenchmarkError("Missing resize checkpoint at \(event.name).") }
                    let from = BenchmarkGrid(columns: terminal.size.columns, rows: terminal.size.rows)
                    let requested = BenchmarkGrid(columns: resize.columns, rows: resize.rows)
                    let history: Int
                    let normalHistory: Int
                    let alternate: Bool
                    do {
                        let snapshot = terminal.snapshot()
                        history = snapshot.history.count
                        normalHistory = snapshot.normalHistoryCount
                        alternate = snapshot.isAlternate
                    }
                    guard history == event.historyRowsBefore, normalHistory == event.normalHistoryRowsBefore else {
                        throw BenchmarkError("Pre-resize history differs from the reference at \(event.name).")
                    }
                    let start = DispatchTime.now().uptimeNanoseconds
                    terminal.resize(to: requested.size)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - start
                    let to = BenchmarkGrid(columns: terminal.size.columns, rows: terminal.size.rows)
                    result.resizes.append((from, requested, to, alternate, history, normalHistory, elapsed))
                }
                if !item.range.isEmpty {
                    let bytes = event.bytes[item.range]
                    let start = DispatchTime.now().uptimeNanoseconds
                    let response = terminal.receive(bytes)
                    result.chunks.append(DispatchTime.now().uptimeNanoseconds - start)
                    reply += response
                    pending -= bytes.count
                    result.appliedBytes += bytes.count
                }
                if item.range.upperBound == event.bytes.count {
                    guard reply == event.reply else { throw BenchmarkError("Reply mismatch at \(event.name).") }
                    result.replyBytes += reply.count
                    reply.removeAll(keepingCapacity: true)
                    if event.hasSemanticInput {
                        let start = DispatchTime.now().uptimeNanoseconds
                        if let encoded = event.encodedInput(using: terminal) {
                            let elapsed = DispatchTime.now().uptimeNanoseconds - start
                            guard encoded == event.input else { throw BenchmarkError("Input mismatch at \(event.name).") }
                            result.keys.append((event.name, encoded.count, elapsed))
                            result.encodedInputBytes += encoded.count
                        }
                    }
                    if checkReference {
                        try event.verify(terminal)
                        if let expected = titles.first, expected.eventIndex == item.event {
                            guard terminal.title == expected.title else {
                                throw BenchmarkError("Window title differs from the recording at event \(item.event) (\(event.name)).")
                            }
                            titles.removeFirst()
                        }
                    }
                }
            }
            guard pending == 0 else { throw BenchmarkError("Undrained output batch.") }
            result.queuedBytesAfterDrain = pending
        }
        guard titles.isEmpty else { throw BenchmarkError("Unreached Codex window-title checkpoint.") }
        result.drain = DispatchTime.now().uptimeNanoseconds - start
        return result
    }

    /// The queue's chunks, split wherever a session restart, palette change or resize changes the terminal.
    private static func spans(of fixture: ReplayFixture) -> [ReceiveRate.Span] {
        var spans = [ReceiveRate.Span()]
        var queue = BurstQueue()
        while queue.fill(from: fixture.events) {
            for item in queue.items {
                let event = fixture.events[item.event]
                if item.range.lowerBound == 0,
                   event.lifecycle?.type == .ready || event.palette != nil || event.resize != nil {
                    spans.append(.init(change: { terminal in
                        event.applyReady(to: &terminal)
                        if let palette = event.palette { terminal.palette = palette }
                        if let resize = event.resize {
                            terminal.resize(to: .init(columns: resize.columns, rows: resize.rows))
                        }
                    }))
                }
                if !item.range.isEmpty { spans[spans.count - 1].chunks.append(event.bytes[item.range]) }
            }
        }
        return spans
    }
}

/// All recording events arrive in one burst. Pull a bounded batch, drain it in
/// order, and only then resume reading. A single large frame can span batches.
private struct BurstQueue {
    static let byteLimit = 8 * 1024
    static let slotLimit = 16

    var items: [(event: Int, range: Range<Int>)] = []
    var bytes = 0
    private var eventIndex = 0
    private var offset = 0

    mutating func fill(from events: [ReplayFixture.Event]) -> Bool {
        items.removeAll(keepingCapacity: true)
        bytes = 0
        while eventIndex < events.count, items.count < Self.slotLimit, bytes < Self.byteLimit {
            let count = events[eventIndex].bytes.count
            let free = Self.byteLimit - bytes
            if bytes > 0 && count - offset > free { break }
            let end = offset + min(count - offset, free)
            items.append((eventIndex, offset..<end))
            bytes += end - offset
            offset = end
            if offset == count {
                eventIndex += 1
                offset = 0
            }
        }
        return !items.isEmpty
    }
}
