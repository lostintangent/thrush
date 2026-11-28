import Foundation
import ThrushFixtures

func outputURL(arguments: [String]) throws -> URL {
    if arguments.isEmpty {
        return URL(filePath: ".build/benchmarks/headless.json")
    }
    guard arguments.count == 2, arguments[0] == "--output", !arguments[1].isEmpty else {
        throw BenchmarkError("Usage: ThrushBench [--output PATH] or ThrushBench --workload FILE COLUMNS ROWS CHUNK WARMUPS PASSES HISTORY")
    }
    return URL(filePath: arguments[1])
}

func printLoad(_ environment: Environment) {
    let load = environment.loadAverage
    let loadValues = String(format: "%.2f / %.2f / %.2f", load.oneMinute, load.fiveMinutes, load.fifteenMinutes)
    let contention = environment.contended ? "contended" : "within core count"
    print("Load (1/5/15 min) \(loadValues)   \(environment.coreCount) active cores"
          + "   \(contention)   thermal \(environment.thermalState)")
}

func run() throws {
    #if DEBUG
    throw BenchmarkError("Run the benchmark with swift run -c release ThrushBench.")
    #else
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--workload" {
        try WorkloadRun.run(arguments: arguments)
        return
    }
    let output = try outputURL(arguments: arguments)
    let report = try HeadlessReport(environment: Environment.read())
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (encoder.encode(report) + Data([0x0A])).write(to: output, options: .atomic)
    report.printTable()
    print("Report \(output.path)")
    #endif
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("ThrushBench: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
