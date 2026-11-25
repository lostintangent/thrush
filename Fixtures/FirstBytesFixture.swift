import CryptoKit
import Foundation

/// Development-only data shared by the headless tests, benchmark and loopback check.
package struct FirstBytesFixture: Sendable {
    package struct Event: Decodable, Sendable {
        package let name: String
        package let offsetMicroseconds: Int
        package let bytes: [UInt8]
        package let reply: [UInt8]
        package let up: [UInt8]?
        package let row: Int
        package let text: String
    }

    private struct Recording: Decodable {
        let version: Int
        let columns: Int
        let rows: Int
        let events: [Event]
    }

    package let columns: Int
    package let rows: Int
    package let events: [Event]
    package let sha256: String

    package static func load() throws -> Self {
        guard let url = Bundle.module.url(forResource: "first-bytes", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        let recording = try JSONDecoder().decode(Recording.self, from: data)
        guard recording.version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported first-bytes fixture version"))
        }
        return Self(
            columns: recording.columns,
            rows: recording.rows,
            events: recording.events,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }
}
