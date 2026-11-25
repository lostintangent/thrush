import Foundation

/// Serves the differential harness: reads one JSON case per line and writes Thrush's checkpoints,
/// their differences from the case's reference checkpoints and a readable report, one JSON line each.
///
/// The harness keeps one process open while it fuzzes and shrinks, so each case costs only its replay.
@main
enum ConformanceServer {
    struct Result: Encodable {
        var checkpoints: [Checkpoint]
        var differences: [Difference]
        var report: String?
    }

    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let testCase = try decoder.decode(ConformanceCase.self, from: Data(line.utf8))
            let checkpoints = testCase.run()
            let result = Result(checkpoints: checkpoints, differences: testCase.differences(in: checkpoints),
                                report: testCase.report(checkpoints))
            FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
        }
    }
}
