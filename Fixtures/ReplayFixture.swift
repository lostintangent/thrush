import Foundation
import ThrushReplay

package typealias ReplayFixture = ThrushReplay.ReplayFixture

extension ReplayFixture {
    package static func load(named name: String, subdirectory: String? = "replays") throws -> Self {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let fixture = try Self.decode(Data(contentsOf: url))
        guard fixture.name == name else { throw CocoaError(.fileReadCorruptFile) }
        return fixture
    }
}
