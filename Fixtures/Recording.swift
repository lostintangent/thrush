import Foundation
import ThrushRecordings

package typealias Recording = ThrushRecordings.Recording

extension Recording {
    package static func load(named name: String, subdirectory: String? = "recordings") throws -> Self {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let fixture = try Self.decode(Data(contentsOf: url))
        guard fixture.name == name else { throw CocoaError(.fileReadCorruptFile) }
        return fixture
    }
}
