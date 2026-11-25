import Foundation
import Testing
@testable import ThrushConformance

// Each generated case replays through ThrushCore and must reach every checkpoint the reference emulator reached.
// Regenerate the cases and lists with `scripts/check-conformance.sh <toy-box checkout> --write`.

extension ConformanceCase: CustomTestStringConvertible {
    public var testDescription: String { name }
}

/// A case where the reference itself is wrong, such as a crash or corrupted history.
/// Thrush must differ in exactly the recorded ways, so a change on either side shows up.
struct ReferenceDefect: Decodable {
    /// Why Thrush's result is the right one.
    var reason: String
    var differences: [Difference]
}

/// The harness's lists, decoded once. A list that fails to decode fails `listsNameCases`.
enum Lists {
    /// Cases Thrush doesn't match yet, by the function they exercise. A listed case that starts
    /// matching fails as an unrecorded known issue, so the list can only shrink.
    static let knownGaps: [String: String] = {
        let gaps = (try? decode([String: [String]].self, from: "KnownGaps")) ?? [:]
        return Dictionary(gaps.flatMap { subject, cases in cases.map { ($0, subject) } }, uniquingKeysWith: { first, _ in first })
    }()

    static let referenceDefects: [String: ReferenceDefect] =
        (try? decode([String: ReferenceDefect].self, from: "ReferenceDefects")) ?? [:]

    static func decode<Value: Decodable>(_ type: Value.Type, from resource: String) throws -> Value {
        guard let url = Bundle.module.url(forResource: resource, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(resource).json"])
        }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

let bundledCases: [ConformanceCase] = {
    let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Cases") ?? []
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.flatMap { url in
        (try? ConformanceCase.load(contentsOf: url)) ?? []
    }
}()

@Suite("Reference conformance")
struct ReferenceConformanceTests {
    @Test("Thrush reaches the reference's checkpoints", arguments: bundledCases)
    func matchesReference(_ testCase: ConformanceCase) {
        let checkpoints = testCase.run()
        if let defect = Lists.referenceDefects[testCase.name] {
            #expect(testCase.differences(in: checkpoints) == defect.differences, Comment(rawValue: defect.reason))
            return
        }
        guard let subject = Lists.knownGaps[testCase.name] else {
            if let report = testCase.report(checkpoints) { Issue.record(Comment(rawValue: report)) }
            return
        }
        // A known gap records only its first difference, so the full reports stay for regressions.
        withKnownIssue("Thrush doesn't match the reference for \(subject) yet") {
            if let first = testCase.differences(in: checkpoints).first {
                Issue.record("At checkpoint \"\(first.checkpoint)\", \(first)")
            }
        }
    }

    @Test func generatedCasesLoad() throws {
        let urls = try #require(Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Cases"))
        for url in urls { _ = try ConformanceCase.load(contentsOf: url) }
        #expect(!bundledCases.isEmpty)
    }

    @Test func listsNameCases() throws {
        let names = Set(bundledCases.map(\.name))
        let gaps = try Lists.decode([String: [String]].self, from: "KnownGaps").values.joined()
        let defects = try Lists.decode([String: ReferenceDefect].self, from: "ReferenceDefects").keys
        #expect(gaps.filter { !names.contains($0) }.sorted() == [])
        #expect(defects.filter { !names.contains($0) }.sorted() == [])
        #expect(Set(gaps).isDisjoint(with: defects))
    }
}
