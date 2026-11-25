import Foundation
import ThrushCore

/// Bytes fed to a fresh terminal, with the checkpoints the reference emulator reached on the same bytes.
///
/// `Fixtures/reference/conformance/harness.mjs` writes these cases from the function corpus,
/// recorded programs and seeded random streams. Thrush never produces its own expectations.
struct ConformanceCase: Decodable, Sendable {
    enum Step: Sendable {
        case write([UInt8])
        case resize(Terminal.Size)
        /// Gives or takes keyboard focus, as the host would.
        case focus(Bool)
        /// Records a checkpoint. A visible-only checkpoint skips history and the inactive normal screen.
        case checkpoint(String, includesHistory: Bool)
    }

    struct Colors: Decodable, Sendable {
        var foreground: String
        var background: String
        var ansi: [String]
    }

    /// A readable identity such as `DCH 1 · at the last column`.
    var name: String
    /// The control function the case exercises, or the program or stream it came from.
    var subject: String
    var size: [Int]
    var palette: Colors?
    var steps: [Step]
    /// The reference's checkpoints, in step order, ending with `end`.
    var expected: [Checkpoint]?

    /// Replays the steps through ThrushCore and records the same checkpoints the reference recorded.
    func run() -> [Checkpoint] {
        var terminal = Terminal(size: Terminal.Size(columns: size[0], rows: size[1]), palette: thrushPalette)
        var replies: [UInt8] = []
        var checkpoints: [Checkpoint] = []
        for step in steps {
            switch step {
            case .write(let bytes):
                replies += terminal.receive(bytes)
            case .resize(let size):
                terminal.resize(to: size)
            case .focus(let focused):
                guard terminal.isFocused != focused else { continue }
                terminal.isFocused = focused
                replies += terminal.encode(.focus(focused))
            case .checkpoint(let name, let includesHistory):
                checkpoints.append(Checkpoint(terminal, name: name, includesHistory: includesHistory, replies: replies))
                replies = []
            }
        }
        return checkpoints
    }

    var input: [UInt8] {
        steps.flatMap { step -> [UInt8] in
            if case .write(let bytes) = step { bytes } else { [] }
        }
    }

    private var thrushPalette: Terminal.Palette {
        guard let palette else { return .default }
        func rgb(_ text: String) -> Terminal.RGB {
            let value = UInt32(text.dropFirst(), radix: 16) ?? 0
            return Terminal.RGB(red: UInt8(value >> 16), green: UInt8(truncatingIfNeeded: value >> 8),
                                blue: UInt8(truncatingIfNeeded: value))
        }
        return Terminal.Palette(foreground: rgb(palette.foreground), background: rgb(palette.background),
                                ansi: palette.ansi.map(rgb))
    }
}

extension ConformanceCase.Step: Decodable {
    private enum CodingKeys: String, CodingKey { case write, resize, focus, checkpoint, scope }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let write = try container.decodeIfPresent(String.self, forKey: .write) {
            guard let bytes = Data(base64Encoded: write) else {
                throw DecodingError.dataCorruptedError(forKey: .write, in: container, debugDescription: "Writes are base64")
            }
            self = .write([UInt8](bytes))
        } else if let size = try container.decodeIfPresent([Int].self, forKey: .resize) {
            self = .resize(Terminal.Size(columns: size[0], rows: size[1]))
        } else if let focused = try container.decodeIfPresent(Bool.self, forKey: .focus) {
            self = .focus(focused)
        } else {
            let scope = try container.decodeIfPresent(String.self, forKey: .scope)
            self = .checkpoint(try container.decode(String.self, forKey: .checkpoint), includesHistory: scope != "visible")
        }
    }
}

extension ConformanceCase {
    /// Loads a generated case file, whose checkpoints name lines by index into shared pools.
    static func load(contentsOf url: URL) throws -> [ConformanceCase] {
        struct Pools: Decodable {
            var cells: [Checkpoint.Cell]
            var lines: [[Int]]
        }
        struct File: Decodable { var cases: [ConformanceCase] }
        let data = try Data(contentsOf: url)
        let pools = try JSONDecoder().decode(Pools.self, from: data)
        let lines = pools.lines.map { line in
            Checkpoint.Line(wrapped: line[0] == 1, cells: line.dropFirst().map { pools.cells[$0] })
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.linePool] = LinePool(lines: lines)
        return try decoder.decode(File.self, from: data).cases
    }
}

final class LinePool: Sendable {
    let lines: [Checkpoint.Line]
    init(lines: [Checkpoint.Line]) { self.lines = lines }
}

extension CodingUserInfoKey {
    static let linePool = CodingUserInfoKey(rawValue: "linePool")!
}
