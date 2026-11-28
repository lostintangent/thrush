import CryptoKit
import Foundation
import ThrushCore

/// Development-only playback data and independent expected screens for the recorded workflows.
package struct Recording: Sendable {
    package static let names = ["shell-log", "vim-edit", "shell-edges", "prompt-bom", "vim-swift-dark", "vim-swift-light",
                                "hardware-keys", "pointer-input", "shell-workflow", "vim-resume", "codex-session", "zsh-clear"]

    package struct Grid: Decodable, Sendable {
        package let columns: Int
        package let rows: Int
    }

    private struct RawPalette: Decodable {
        let foreground: String
        let background: String
        let ansi: [String]

        func palette() throws -> Terminal.Palette {
            guard ansi.count == 16 else { throw Failure("A fixture palette requires 16 ANSI colors.") }
            return try Terminal.Palette(foreground: Self.rgb(foreground), background: Self.rgb(background),
                                        ansi: ansi.map(Self.rgb))
        }

        private static func rgb(_ text: String) throws -> Terminal.RGB {
            let digits = text.dropFirst()
            guard text.first == "#", text.utf8.count == 7, digits.allSatisfy(\.isHexDigit),
                  let value = UInt32(digits, radix: 16) else {
                throw Failure("Invalid fixture color \(text). Expected #rrggbb.")
            }
            return .init(red: UInt8(value >> 16), green: UInt8(truncatingIfNeeded: value >> 8),
                         blue: UInt8(truncatingIfNeeded: value))
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    fileprivate struct Action: Decodable, Sendable {
        enum Kind: String, Decodable { case text, paste, key, pointer }
        let kind: Kind
        let value: String
        let modifiers: [String]?
        let pointer: PointerFields?
        private static let pointerActions: [String: Terminal.Input.Pointer.Action] = [
            "press": .press, "release": .release, "move": .move,
        ]
        private static let pointerButtons: [String: Terminal.Input.Pointer.Button] = [
            "left": .left, "middle": .middle, "right": .right, "none": .none,
            "wheelUp": .wheelUp, "wheelDown": .wheelDown,
        ]

        struct PointerFields: Decodable, Sendable {
            let button: String
            let column: Int
            let row: Int
        }

        private func modifierFlags() throws -> Terminal.Input.Modifiers {
            var flags: Terminal.Input.Modifiers = []
            for modifier in modifiers ?? [] {
                switch modifier {
                case "shift": flags.insert(.shift)
                case "alt": flags.insert(.alt)
                case "control": flags.insert(.control)
                default: throw Failure("Unknown recorded modifier \(modifier)")
                }
            }
            return flags
        }

        func terminalInput() throws -> Terminal.Input {
            switch kind {
            case .pointer:
                guard let pointer, let action = Self.pointerActions[value],
                      let button = Self.pointerButtons[pointer.button] else {
                    throw Failure("Invalid pointer event.")
                }
                return .pointer(.init(action, button: button, row: pointer.row, column: pointer.column,
                                      modifiers: try modifierFlags()))
            case .text: return .text(value)
            case .paste: return .paste(value)
            case .key:
                let named: [String: Terminal.Input.Key] = [
                    "up": .up, "down": .down, "left": .left, "right": .right, "home": .home, "end": .end,
                    "pageUp": .pageUp, "pageDown": .pageDown, "delete": .delete, "enter": .enter,
                    "escape": .escape, "backspace": .backspace, "tab": .tab,
                ]
                guard let key = named[value] ?? (value.count == 1 ? value.first.map { .character($0) } : nil)
                else { throw Failure("Unknown recorded key \(value)") }
                return .key(key, modifiers: try modifierFlags())
            }
        }
    }

    package struct Lifecycle: Decodable, Sendable {
        package enum Kind: String, Decodable, Sendable { case detach, ready }
        package let type: Kind
        package let clientId: String
        package let resumed: Bool?
    }

    package struct Copy: Decodable, Sendable {
        package struct Position: Decodable, Sendable {
            package let row: Int
            package let column: Int
        }

        package let start: Position
        package let end: Position
        package let text: String
    }

    private struct RawEvent: Decodable {
        let name: String
        let offsetMicroseconds: Int
        let bytes: Data?
        let input: Data?
        let reply: Data?
        let resize: Grid?
        let palette: RawPalette?
        let lifecycle: Lifecycle?
        let copy: Copy?
        let normalHistoryRowsBefore, historyRowsBefore: Int?
        let action: Action?
        let checkpoint: Checkpoint?
    }

    private struct RawRecording: Decodable {
        let name: String
        let version: Int
        let columns: Int
        let rows: Int
        let events: [RawEvent]
    }

    package struct Event: Sendable {
        package let name: String
        package let offsetMicroseconds: Int
        package let bytes: [UInt8]
        package let input: [UInt8]
        package let reply: [UInt8]
        package let resize: Grid?
        package let palette: Terminal.Palette?
        package let lifecycle: Lifecycle?
        package let copy: Copy?
        package var hasSemanticInput: Bool { semanticInput != nil }
        package let normalHistoryRowsBefore, historyRowsBefore: Int?
        package let checkpoint: Checkpoint?
        package let semanticInput: Terminal.Input?

        /// A ready control precedes any serialized replay on the new attachment.
        package func applyReady(to terminal: inout Terminal) {
            if lifecycle?.type == .ready { terminal = Terminal(size: terminal.size, palette: terminal.palette) }
        }

        package func encodedInput(using terminal: Terminal) -> [UInt8]? {
            semanticInput.map { terminal.encode($0) }
        }

        package func verify(_ terminal: Terminal) throws {
            if let encoded = encodedInput(using: terminal), encoded != input {
                throw Failure("\(name) input: got \(encoded), expected \(input)")
            }
            guard let checkpoint else { return }
            try check(Checkpoint(terminal, name: name, includesHistory: true), against: checkpoint)
        }

        package func verify(_ snapshot: Terminal.Snapshot) throws {
            guard var expected = checkpoint else { return }
            // A snapshot holds neither the title nor the normal screen behind the alternate one.
            expected.title = ""
            expected.normal = nil
            try check(Checkpoint(snapshot, name: name, includesHistory: true), against: expected)
        }

        private func check(_ actual: Checkpoint, against expected: Checkpoint) throws {
            let differences = actual.differences(from: expected)
            guard differences.isEmpty else {
                throw Failure("\(name): " + differences.prefix(4).map(\.description).joined(separator: "; "))
            }
        }
    }

    package let name: String
    package let columns: Int
    package let rows: Int
    package let events: [Event]
    package let sha256: String

    package static func load(named name: String, subdirectory: String? = "recordings") throws -> Self {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        let fixture = try Self.decode(Data(contentsOf: url))
        guard fixture.name == name else { throw CocoaError(.fileReadCorruptFile) }
        return fixture
    }

    package static func decode(_ data: Data) throws -> Self {
        let recording = try LinePool(decoding: data).decoder.decode(RawRecording.self, from: data)
        guard recording.version == 1 else { throw Failure("Unsupported recording version \(recording.version)") }
        guard recording.columns > 0, recording.rows > 0 else { throw Failure("Missing terminal grid") }
        let events = try recording.events.map { event in
            Event(name: event.name, offsetMicroseconds: event.offsetMicroseconds,
                  bytes: Array(event.bytes ?? Data()), input: Array(event.input ?? Data()),
                  reply: Array(event.reply ?? Data()), resize: event.resize, palette: try event.palette?.palette(),
                  lifecycle: event.lifecycle, copy: event.copy,
                  normalHistoryRowsBefore: event.normalHistoryRowsBefore, historyRowsBefore: event.historyRowsBefore,
                  checkpoint: event.checkpoint,
                  semanticInput: try event.action?.terminalInput())
        }
        return Self(name: recording.name, columns: recording.columns, rows: recording.rows, events: events,
                    sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
