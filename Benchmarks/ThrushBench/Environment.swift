import Darwin
import Foundation

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct Environment: Encodable {
    struct LoadAverage: Encodable {
        let oneMinute: Double
        let fiveMinutes: Double
        let fifteenMinutes: Double

        init() throws {
            var samples = [Double](repeating: 0, count: 3)
            guard getloadavg(&samples, 3) == 3 else {
                throw BenchmarkError("Could not read the system load averages.")
            }
            oneMinute = samples[0]
            fiveMinutes = samples[1]
            fifteenMinutes = samples[2]
        }
    }

    let commit: String
    let worktreeDirty: Bool
    let hardwareModel: String
    let processor: String
    let operatingSystem: String
    let swiftToolchain: String
    let coreCount: Int
    let loadAverage: LoadAverage
    let contended: Bool
    let thermalState: String
    let powerSource: String
    let lowPowerMode: Bool

    static func read() throws -> Environment {
        let info = ProcessInfo.processInfo
        let battery = try command("/usr/bin/pmset", ["-g", "batt"])
        let source = battery.split(separator: "'").dropFirst().first.map(String.init) ?? "unknown"
        // Identify the checkout that supplied this build even when the caller uses --package-path.
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let git = ["-C", packageRoot.path]
        let commit = try command("/usr/bin/git", git + ["rev-parse", "HEAD"])
        let dirty = try !command("/usr/bin/git", git + ["status", "--porcelain"]).isEmpty
        let model = try command("/usr/sbin/sysctl", ["-n", "hw.model"])
        let processor = try command("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
        let toolchain = try command("/usr/bin/env", ["swift", "--version"])

        let cores = info.activeProcessorCount
        let load = try LoadAverage()
        let thermal: String = switch info.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return Environment(
            commit: commit, worktreeDirty: dirty, hardwareModel: model, processor: processor,
            operatingSystem: info.operatingSystemVersionString, swiftToolchain: toolchain,
            coreCount: cores, loadAverage: load, contended: load.oneMinute > Double(cores),
            thermalState: thermal, powerSource: source, lowPowerMode: info.isLowPowerModeEnabled
        )
    }

    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw BenchmarkError("\(executable) \(arguments.joined(separator: " ")) exited with status \(process.terminationStatus). \(output)")
        }
        return output
    }
}
