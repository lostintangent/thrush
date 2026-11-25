import Foundation
import ThrushFixtures

struct Report: Encodable {
    let schemaVersion = 1
    let fixture = "first-bytes.json"
    let fixtureSHA256: String
    let recordedAt: Date
    let buildConfiguration = "release"
    let columns: Int
    let rows: Int
    let environment: Environment
    let replay: Replay
}

func outputURL(arguments: [String]) throws -> URL {
    if arguments.isEmpty {
        return URL(filePath: ".build/benchmarks/first-bytes.json")
    }
    guard arguments.count == 2, arguments[0] == "--output", !arguments[1].isEmpty else {
        throw BenchmarkError("Usage: ThrushBench [--output PATH], ThrushBench --connection [--output PATH], ThrushBench --transport [--output PATH], or ThrushBench --render MAC_APP [--output PATH]")
    }
    return URL(filePath: arguments[1])
}

func printTable(_ report: Report) {
    let replay = report.replay
    let width = max("Operation".count, replay.operations.map(\.name.count).max() ?? 0)
    func row(_ name: String, _ bytes: String, _ median: String, _ p95: String) {
        let label = name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(label)  \(bytes.leftPadded(to: 6))  \(median.leftPadded(to: 8))  \(p95.leftPadded(to: 8))")
    }
    func duration(_ nanoseconds: UInt64) -> String {
        nanoseconds == 0 ? "sub-tick" : String(nanoseconds)
    }
    let revision = report.environment.commit.prefix(12)
    let state = report.environment.worktreeDirty ? " (dirty)" : ""
    print("ThrushBench   \(report.columns) × \(report.rows)   \(report.environment.processor)   \(revision)\(state)")
    printLoad(report.environment)
    print("\(replay.measuredReplays) measured replays after \(replay.warmupReplays) warmups\n")
    row("Operation", "Bytes", "p50 ns", "p95 ns")
    for operation in replay.operations {
        row(operation.name, operation.bytesPerCall.map(String.init) ?? "–",
            duration(operation.timing.p50Nanoseconds), duration(operation.timing.p95Nanoseconds))
    }
    print()
    print(String(format: "Receive %.2f MiB/s", replay.receiveMiBPerSecond)
          + "   \(replay.receivedBytes) bytes received   \(replay.appliedBytes) applied")
    print("Burst \(replay.maximumBurstQueuedBytes) bytes   drain p95 \(replay.burstDrain.p95Nanoseconds) ns"
          + "   \(replay.queuedBytesAfterDrain) bytes pending")
    print("Recorded one-second peak \(replay.fixturePeakBytesInOneSecond) bytes")
}

func printLoad(_ environment: Environment) {
    let load = environment.loadAverage
    let loadValues = String(format: "%.2f / %.2f / %.2f", load.oneMinute, load.fiveMinutes, load.fifteenMinutes)
    let contention = environment.contended ? "contended" : "within core count"
    print("Load (1/5/15 min) \(loadValues)   \(environment.coreCount) active cores"
          + "   \(contention)   thermal \(environment.thermalState)")
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        String(repeating: " ", count: Swift.max(0, width - count)) + self
    }
}

func run() throws {
    #if DEBUG
    throw BenchmarkError("Run the benchmark with swift run -c release ThrushBench.")
    #else
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--render" || arguments.first == "--interactions" {
        try runPackagedRenderer(arguments: arguments)
        return
    }
    if arguments.first == "--serialize-replay" {
        try serializeCheckpoints(arguments: arguments)
        return
    }
    if arguments.first == "--connection" || arguments.first == "--transport" {
        try runConnectionBenchmark(arguments: arguments)
        return
    }
    if arguments.first == "--workload" {
        try WorkloadRun.run(arguments: arguments)
        return
    }
    let output = try outputURL(arguments: arguments)
    let fixture = try FirstBytesFixture.load()
    let environment = try Environment.read()
    let report = try Report(fixtureSHA256: fixture.sha256, recordedAt: Date(),
                            columns: fixture.columns, rows: fixture.rows,
                            environment: environment, replay: Replay.measure(fixture))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try encoder.encode(report) + Data([0x0A])
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: output, options: .atomic)
    printTable(report)
    print("Report \(output.path)")

    let headless = try HeadlessReport(environment: Environment.read())
    let stem = output.deletingPathExtension().lastPathComponent
    let name = stem == "first-bytes" ? "headless.json" : "\(stem)-headless.json"
    let headlessOutput = output.deletingLastPathComponent().appendingPathComponent(name)
    try (encoder.encode(headless) + Data([0x0A])).write(to: headlessOutput, options: .atomic)
    headless.printTable()
    print("Report \(headlessOutput.path)")
    #endif
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ThrushBench: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
