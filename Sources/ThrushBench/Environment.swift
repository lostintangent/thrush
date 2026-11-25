import Foundation

struct BenchmarkError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct Environment: Encodable {
    let commit: String
    let worktreeDirty: Bool
    let hardwareModel: String
    let processor: String
    let operatingSystem: String
    let swiftToolchain: String
    let thermalState: String
    let powerSource: String
    let lowPowerMode: Bool
    let displayInterval = "headless"

    static func read() throws -> Environment {
        let info = ProcessInfo.processInfo
        let thermal: String = switch info.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        let battery = try command("/usr/bin/pmset", ["-g", "batt"])
        let source = battery.split(separator: "'").dropFirst().first.map(String.init) ?? "unknown"
        // Identify the checkout that supplied this build even when the caller uses --package-path.
        let packageRoot = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let git = ["-C", packageRoot.path]
        return try Environment(
            commit: command("/usr/bin/git", git + ["rev-parse", "HEAD"]),
            worktreeDirty: !command("/usr/bin/git", git + ["status", "--porcelain"]).isEmpty,
            hardwareModel: command("/usr/sbin/sysctl", ["-n", "hw.model"]),
            processor: command("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
            operatingSystem: info.operatingSystemVersionString,
            swiftToolchain: command("/usr/bin/env", ["swift", "--version"]),
            thermalState: thermal, powerSource: source, lowPowerMode: info.isLowPowerModeEnabled
        )
    }

    private static func command(_ executable: String, _ arguments: [String]) throws -> String {
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
            throw BenchmarkError("Could not collect metadata with \(executable): \(output)")
        }
        return output
    }
}
