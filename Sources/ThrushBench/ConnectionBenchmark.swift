import CryptoKit
import Foundation

private struct PeerRun: Decodable {
    struct Observation: Decodable {
        let name: String
        let nanoseconds: UInt64
    }
    let bunVersion: String
    let attachmentCount: Int
    let freshShells: Int
    let takeovers: Int
    let observations: [Observation]
}

private struct ConnectionInterval: Encodable {
    let name: String
    let samplesNanoseconds: [UInt64]
    let timing: Timing
}

private struct ConnectionReport: Encodable {
    let schemaVersion = 1
    let buildConfiguration = "release"
    let recordedAt = Date()
    let workload = "scripts/lifecycle-peer.ts"
    let workloadSHA256: String
    let measurement = "Scripted macOS loopback, peer-observed with Bun.nanoseconds()"
    let measuresPresentation = false
    let measuresPhysicalIPhone = false
    let warmupPasses = 1
    let measuredPasses: Int
    let attachmentGrid = BenchmarkGrid(columns: 16, rows: 3)
    let resizes = [BenchmarkGrid(columns: 18, rows: 3), BenchmarkGrid(columns: 17, rows: 3)]
    let virtualOrphanLifetimeMilliseconds = 30_000
    let environment: Environment
    let bunVersion: String
    let attachmentsPerPass: Int
    let freshShellsPerPass: Int
    let takeoversPerPass: Int
    let intervals: [ConnectionInterval]
}

/// All time samples come from the existing peer's monotonic clock. Each invocation must also pass
/// the Swift host's screen/mode checkpoints and the peer's exact wire assertions.
func runConnectionBenchmark(arguments: [String]) throws {
    guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--output" && !arguments[2].isEmpty) else {
        throw BenchmarkError("Usage: ThrushBench --connection [--output PATH]")
    }
    let output = URL(filePath: arguments.count == 3 ? arguments[2] : ".build/benchmarks/connection.json")
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let peer = root.appending(path: "scripts/lifecycle-peer.ts")
    let swift = ["swift", "build", "-c", "release", "--package-path", root.path]
    // swift run builds only ThrushBench. Build the matching optimized checker outside all timed intervals.
    _ = try Environment.command("/usr/bin/env", swift + ["--product", "ThrushLoopbackCheck"])
    let bin = try Environment.command("/usr/bin/env", swift + ["--show-bin-path"], captureDiagnostics: false)
    let client = URL(filePath: bin).appending(path: "ThrushLoopbackCheck")
    let digest = SHA256.hash(data: try Data(contentsOf: peer)).map { String(format: "%02x", $0) }.joined()
    let environment = try Environment.read()

    func runPeer() throws -> PeerRun {
        let json = try Environment.command("/usr/bin/env", ["bun", peer.path, client.path, "--observe"], captureDiagnostics: false)
        return try JSONDecoder().decode(PeerRun.self, from: Data(json.utf8))
    }
    let warmup = try runPeer()
    let runs = try (0..<5).map { _ in try runPeer() }
    let names = warmup.observations.map(\.name)
    guard !names.isEmpty, runs.allSatisfy({
        $0.observations.map(\.name) == names && $0.attachmentCount == warmup.attachmentCount
        && $0.freshShells == warmup.freshShells && $0.takeovers == warmup.takeovers
    }) else { throw BenchmarkError("The scripted lifecycle workload changed between passes.") }
    let intervals = names.enumerated().map { index, name in
        let samples = runs.map { $0.observations[index].nanoseconds }
        return ConnectionInterval(name: name, samplesNanoseconds: samples, timing: Timing(samples))
    }
    let report = ConnectionReport(
        workloadSHA256: digest, measuredPasses: runs.count, environment: environment,
        bunVersion: warmup.bunVersion, attachmentsPerPass: warmup.attachmentCount,
        freshShellsPerPass: warmup.freshShells, takeoversPerPass: warmup.takeovers, intervals: intervals
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (encoder.encode(report) + Data([0x0A])).write(to: output, options: .atomic)
    print("\nScripted connection lifecycle   macOS loopback   peer-observed   \(runs.count) measured passes")
    printLoad(environment)
    print("Interval                                        p50 ms    p95 ms")
    for interval in intervals {
        let name = interval.name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print(name + String(format: "%8.3f  %8.3f", Double(interval.timing.p50Nanoseconds) / 1e6,
                            Double(interval.timing.p95Nanoseconds) / 1e6))
    }
    print("Report \(output.path)")
}
