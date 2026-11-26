import Foundation
import ThrushFixtures

struct HeadlessReport: Encodable {
    let schemaVersion = 1
    let buildConfiguration = "release"
    let recordedAt = Date()
    let referenceRefreshHz = 120
    let referenceIntervalNanoseconds = HeadlessRecording.displayIntervalNanoseconds
    let environment: Environment
    let bulk: [BulkText]
    let recordings: [HeadlessRecording]
    let shellTransitions: ShellTransitions

    init(environment: Environment) throws {
        self.environment = environment
        bulk = try BulkText.measure()
        recordings = try Recording.names.map { name in
            try HeadlessRecording.measure(Recording.load(named: name), named: name)
        }
        let destinations: [BenchmarkGrid] = [.portrait, .landscape, .desktop]
        guard let log = recordings.first(where: { $0.name == "shell-log" }),
              let vim = recordings.first(where: { $0.name == "vim-edit" }),
              log.resizes.filter({ !$0.alternate }).allSatisfy({ $0.normalHistoryRowsBefore == 1_000 }),
              log.resizes.first(where: \.alternate)?.normalHistoryRowsBefore == 1_000,
              log.resizes.filter({ !$0.alternate }).map(\.to) == destinations,
              vim.resizes.filter(\.alternate).map(\.to) == destinations else {
            throw BenchmarkError("The resize workloads require full shell history and a Vim alternate-screen round trip.")
        }
        shellTransitions = try ShellTransitions.measure()
    }

    func printTable() {
        print("\nHeadless recordings   120 Hz comparison interval 8.333 ms")
        printLoad(environment)
        print("Workload            Grid       Receive MiB/s   Chunk p95 µs   Recorded peak B/s    Rate / peak   Queue high B   Drain p95 ms")
        for sample in bulk {
            let prefix = columns("Plain ASCII", sample.grid)
            print(prefix + String(format: "%13.2f %14.3f", sample.receiveMiBPerSecond,
                                  Double(sample.chunkTime.p95Nanoseconds) / 1e3))
        }
        for recording in recordings {
            let prefix = columns(recording.name, recording.initialGrid)
            print(prefix + String(format: "%13.2f %14.3f %19d %14.2f %14d %14.3f", recording.receiveMiBPerSecond,
                                  Double(recording.chunkTime.p95Nanoseconds) / 1e3, recording.fixturePeakBytesInOneSecond,
                                  recording.fixturePeakMultiple, recording.maximumQueuedBytes,
                                  Double(recording.burstDrain.p95Nanoseconds) / 1e6))
        }
        for recording in recordings {
            if let time = recording.paletteChangeTime {
                print("\nHost palette change (\(recording.name)): p50 \(time.p50Nanoseconds) ns, p95 \(time.p95Nanoseconds) ns.")
            }
        }
        print("\nResize              Screen       From → To          Active history   Normal history   p50 ms   p95 ms")
        for recording in recordings {
            for resize in recording.resizes {
                let name = recording.name.padding(toLength: 20, withPad: " ", startingAt: 0)
                let screen = resize.alternate ? "alternate    " : "normal       "
                let grid = "\(resize.from) → \(resize.to)".padding(toLength: 18, withPad: " ", startingAt: 0)
                print(name + screen + grid + String(format: "%14d %16d %8.3f %8.3f", resize.historyRowsBefore,
                                                    resize.normalHistoryRowsBefore,
                                                    Double(resize.timing.p50Nanoseconds) / 1e6,
                                                    Double(resize.timing.p95Nanoseconds) / 1e6))
            }
        }
        print("\nShell transitions at \(shellTransitions.grid)   History before → after   p50 µs   p95 µs")
        for (name, sample) in [("Start new shell", shellTransitions.startNewShell),
                               ("Prepare for replay", shellTransitions.prepareForReplay)] {
            print(name.padding(toLength: 23, withPad: " ", startingAt: 0)
                  + String(format: "%9d → %-9d %8.3f %8.3f", sample.historyRowsBefore, sample.historyRowsAfter,
                           Double(sample.timing.p50Nanoseconds) / 1e3, Double(sample.timing.p95Nanoseconds) / 1e3))
        }
    }

    private func columns(_ name: String, _ grid: BenchmarkGrid) -> String {
        name.padding(toLength: 20, withPad: " ", startingAt: 0)
        + grid.description.padding(toLength: 8, withPad: " ", startingAt: 0)
    }
}
