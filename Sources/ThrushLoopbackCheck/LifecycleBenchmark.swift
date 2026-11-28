import CryptoKit
import Foundation

private struct PeerRun: Decodable {
    struct Observation: Decodable {
        let name: String
        let nanoseconds: UInt64
    }
    let bunVersion: String
    let observations: [Observation]
}

private struct Interval: Encodable {
    let name: String
    let samplesNanoseconds: [UInt64]
    let p50Nanoseconds: UInt64
    let p95Nanoseconds: UInt64

    /// Nearest rank, so with five samples p95 is the slowest.
    init(name: String, samples: [UInt64]) {
        let sorted = samples.sorted()
        self.name = name
        samplesNanoseconds = samples
        p50Nanoseconds = sorted[(sorted.count * 50 - 1) / 100]
        p95Nanoseconds = sorted[(sorted.count * 95 - 1) / 100]
    }
}

private struct Environment: Encodable {
    struct LoadAverage: Encodable {
        let oneMinute, fiveMinutes, fifteenMinutes: Double
    }
    let commit: String
    let worktreeDirty: Bool
    let processor: String
    let coreCount: Int
    let loadAverage: LoadAverage
    let thermalState: String
}

private struct Report: Encodable {
    let recordedAt = Date()
    let workloadSHA256: String
    let bunVersion: String
    let environment: Environment
    let intervals: [Interval]
}

extension LoopbackCheck {
    /// Times the exchange `scripts/lifecycle-peer.ts` checks, against this Release build of the client.
    /// The peer brackets each named interval with `Bun.nanoseconds()`. One warmup and five measured
    /// passes each start a fresh peer and client.
    static func benchmarkLifecycle() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let peer = root.appending(path: "scripts/lifecycle-peer.ts")
        guard let client = Bundle.main.executablePath else { throw CheckFailure("Could not find this executable") }
        let passes = try (0...5).map { _ in
            try JSONDecoder().decode(PeerRun.self, from: run("bun", peer.path, client, "--observe"))
        }.dropFirst()
        let names = passes.first!.observations.map(\.name)
        guard passes.allSatisfy({ $0.observations.map(\.name) == names }) else {
            throw CheckFailure("The peer observed different intervals between passes")
        }
        let intervals = names.indices.map { index in
            Interval(name: names[index], samples: passes.map { $0.observations[index].nanoseconds })
        }

        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { throw CheckFailure("Could not read the load average") }
        let thermalState = switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        let environment = try Environment(
            commit: text(run("git", "-C", root.path, "rev-parse", "HEAD")),
            worktreeDirty: !text(run("git", "-C", root.path, "status", "--porcelain")).isEmpty,
            processor: text(run("sysctl", "-n", "machdep.cpu.brand_string")),
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            loadAverage: .init(oneMinute: load[0], fiveMinutes: load[1], fifteenMinutes: load[2]),
            thermalState: thermalState
        )
        let digest = SHA256.hash(data: try Data(contentsOf: peer)).map { String(format: "%02x", $0) }.joined()
        let report = Report(workloadSHA256: digest, bunVersion: passes.first!.bunVersion,
                            environment: environment, intervals: intervals)

        let output = root.appending(path: ".build/benchmarks/websocket.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (encoder.encode(report) + Data([0x0A])).write(to: output, options: .atomic)

        print("WebSocket lifecycle over loopback   \(passes.count) measured passes   \(environment.processor)")
        print(String(format: "Load %.2f on %d cores   thermal %@", load[0], environment.coreCount, thermalState))
        print("Interval                                        p50 ms    p95 ms")
        for interval in intervals {
            print(interval.name.padding(toLength: 46, withPad: " ", startingAt: 0)
                  + String(format: "%8.3f  %8.3f", Double(interval.p50Nanoseconds) / 1e6, Double(interval.p95Nanoseconds) / 1e6))
        }
        print("Report \(output.path)")
    }

    private static func run(_ arguments: String...) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CheckFailure("\(arguments.joined(separator: " ")) exited with status \(process.terminationStatus)")
        }
        return data
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
