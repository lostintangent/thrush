import Foundation

/// Serves the differential harness: reads one JSON request per line and writes one JSON result per line.
///
/// The harness keeps one process open while it fuzzes and shrinks, so each case costs only its replay.
@main
enum ConformanceServer {
    enum Request: Decodable {
        /// A case to run, answered with Thrush's checkpoints, their differences from the case's reference
        /// checkpoints and a readable report.
        case run(ConformanceCase)
        /// `{ replays: case, probe: [part] }`, answered with ThrushCore's replays of the case and where a
        /// terminal resumed from each first differs from the live one.
        case replays(ConformanceCase, probe: [[UInt8]])
        /// `{ compare: [live, resumed] }`, two lists of checkpoints, answered with the differences between a
        /// live and a resumed terminal's, so the reference's replay check describes them the same way.
        case compare(live: [Checkpoint], resumed: [Checkpoint])

        private enum CodingKeys: String, CodingKey { case replays, probe, compare }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if container.contains(.replays) {
                self = .replays(try container.decode(ConformanceCase.self, forKey: .replays),
                                probe: try container.decode([Data].self, forKey: .probe).map { [UInt8]($0) })
            } else if container.contains(.compare) {
                let pair = try container.decode([[Checkpoint]].self, forKey: .compare)
                self = .compare(live: pair[0], resumed: pair[1])
            } else {
                self = .run(try ConformanceCase(from: decoder))
            }
        }
    }

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
            let result: any Encodable
            switch try decoder.decode(Request.self, from: Data(line.utf8)) {
            case .run(let testCase):
                let checkpoints = testCase.run()
                result = Result(checkpoints: checkpoints, differences: testCase.differences(in: checkpoints),
                                report: testCase.report(checkpoints))
            case .replays(let testCase, let probe):
                result = ["replays": testCase.replays(probe: probe)]
            case .compare(let live, let resumed):
                result = ["differences": ConformanceCase.differences(resumed, from: live)]
            }
            FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
        }
    }
}
