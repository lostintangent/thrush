import Foundation

/// Window-title observations from the reference terminal used for the recorded workflows.
package struct WindowTitleFixture: Decodable, Sendable {
    package struct Case: Decodable, Sendable {
        package struct Step: Decodable, Sendable {
            package let bytes: Data
            package let title: String
        }
        package let name: String
        package let steps: [Step]
    }

    package struct Recording: Decodable, Sendable {
        package struct Checkpoint: Decodable, Sendable {
            package let eventIndex: Int
            package let title: String
        }
        package let fixtureSHA256: String
        package let checkpoints: [Checkpoint]
    }

    package let cases: [Case]
    package let codex: Recording

    package static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "window-title", withExtension: "json",
                                          subdirectory: "replays/metadata") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
