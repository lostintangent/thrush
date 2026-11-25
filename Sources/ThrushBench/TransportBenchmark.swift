import CryptoKit
import Foundation
import ThrushFixtures

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

private struct WebSocketInterval: Encodable {
    let name: String
    let samplesNanoseconds: [UInt64]
    let timing: Timing
}

private struct WebSocketReport: Encodable {
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
    let intervals: [WebSocketInterval]
}

private struct AppTransportReport: Encodable {
    let schemaVersion = 1
    let buildConfiguration = "release"
    let recordedAt = Date()
    let workload = "Fixtures/first-bytes.json"
    let workloadSHA256: String
    let measurement = "Headless macOS host, from first read through EOF, including terminal replies"
    let measuresPresentation = false
    let measuresPhysicalIPhone = false
    let warmupPasses = 1
    let measuredPasses: Int
    let chunksPerPass, verifiedBytesPerPass, replyBytesPerPass: Int
    let samplesNanoseconds: [UInt64]
    let timing: Timing
    let environment: Environment
}

private func writeReport(_ report: some Encodable, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (encoder.encode(report) + Data([0x0A])).write(to: output, options: .atomic)
}

/// Build the matching optimized checker outside the timed intervals.
func runTransportBenchmark(arguments: [String]) throws {
    guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--output" && !arguments[2].isEmpty) else {
        throw BenchmarkError("Usage: ThrushBench \(arguments[0]) [--output PATH]")
    }
    let appTransport = arguments[0] == "--app-transport"
    let defaultOutput = appTransport ? ".build/benchmarks/app-transport.json" : ".build/benchmarks/websocket.json"
    let output = URL(filePath: arguments.count == 3 ? arguments[2] : defaultOutput)
    let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let swift = ["swift", "build", "-c", "release", "--package-path", root.path]
    _ = try Environment.command("/usr/bin/env", swift + ["--product", "ThrushLoopbackCheck"])
    let bin = try Environment.command("/usr/bin/env", swift + ["--show-bin-path"], captureDiagnostics: false)
    let client = URL(filePath: bin).appending(path: "ThrushLoopbackCheck")
    let environment = try Environment.read()
    if appTransport {
        let fixture = try FirstBytesFixture.load()
        let json = try Environment.command(client.path, ["--transport"], captureDiagnostics: false)
        let samples = try JSONDecoder().decode([UInt64].self, from: Data(json.utf8))
        guard !samples.isEmpty else { throw BenchmarkError("The app transport returned no samples.") }
        let report = AppTransportReport(workloadSHA256: fixture.sha256, measuredPasses: samples.count,
                                  chunksPerPass: fixture.events.count,
                                  verifiedBytesPerPass: fixture.events.reduce(0) { $0 + $1.bytes.count },
                                  replyBytesPerPass: fixture.events.reduce(0) { $0 + $1.reply.count },
                                  samplesNanoseconds: samples, timing: Timing(samples), environment: environment)
        try writeReport(report, to: output)
        print("App transport   \(report.chunksPerPass) chunks   \(report.verifiedBytesPerPass) verified bytes per pass")
        print("p50 \(report.timing.p50Nanoseconds) ns   p95 \(report.timing.p95Nanoseconds) ns")
        print("Report \(output.path)")
        return
    }
    let peer = root.appending(path: "scripts/lifecycle-peer.ts")
    let digest = SHA256.hash(data: try Data(contentsOf: peer)).map { String(format: "%02x", $0) }.joined()

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
        return WebSocketInterval(name: name, samplesNanoseconds: samples, timing: Timing(samples))
    }
    let report = WebSocketReport(
        workloadSHA256: digest, measuredPasses: runs.count, environment: environment,
        bunVersion: warmup.bunVersion, attachmentsPerPass: warmup.attachmentCount,
        freshShellsPerPass: warmup.freshShells, takeoversPerPass: warmup.takeovers, intervals: intervals
    )
    try writeReport(report, to: output)
    print("\nScripted WebSocket lifecycle   macOS loopback   peer-observed   \(runs.count) measured passes")
    printLoad(environment)
    print("Interval                                        p50 ms    p95 ms")
    for interval in intervals {
        let name = interval.name.padding(toLength: 46, withPad: " ", startingAt: 0)
        print(name + String(format: "%8.3f  %8.3f", Double(interval.timing.p50Nanoseconds) / 1e6,
                            Double(interval.timing.p95Nanoseconds) / 1e6))
    }
    print("Report \(output.path)")
}
