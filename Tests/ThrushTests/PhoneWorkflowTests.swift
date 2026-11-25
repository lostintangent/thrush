#if os(iOS)
import Testing
import ThrushCore
import ThrushFixtures
@testable import Thrush
import UIKit

@MainActor
@Test(arguments: ["shell-workflow", "vim-resume", "codex-session"])
func phoneReplaysRecordedWorkflows(_ name: String) throws {
    let fixture = try ReplayFixture.load(named: name)
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    var wire: [UInt8] = []
    view.onInput = { wire += terminal.encode($0) }
    let spokenAt = [
        "Typed command": "./builx",
        "Pasted build command": "./build 126 130",
        "Edited scratch file": "note: 界 e\u{301}first line",
        "Vim serialized replay": "note: 界 e\u{301}first line",
        "Codex working": "esc to interrupt",
        "First three songbirds streamed": "3. Eurasian blue tit",
        "Received Codex answer": "12. European robin",
        "Earlier transcript page": "Song thrush",
        "Later transcript page": "Eurasian skylark",
        "Returned to shell": "thrush$ ",
    ]

    for event in fixture.events {
        if event.lifecycle?.type == .ready {
            event.applyReady(to: &terminal)
            view.reset()
        }
        if let palette = event.palette { terminal.palette = palette }
        if let grid = event.resize { terminal.resize(to: .init(columns: grid.columns, rows: grid.rows)) }
        if let input = event.semanticInput {
            wire.removeAll(keepingCapacity: true)
            try performRecordedInput(input, in: view)
            #expect(wire == event.input, "\(name): \(event.name)")
        }
        #expect(terminal.receive(event.bytes) == event.reply, "\(name): \(event.name)")
        view.display(terminal)
        if let wanted = spokenAt[event.name], event.checkpoint != nil {
            let lines = transcript.accessibilityElements?.compactMap { ($0 as? UIAccessibilityElement)?.accessibilityLabel } ?? []
            #expect(lines.contains(where: { $0.contains(wanted) }), "\(name): \(event.name)")
        }
        if let copy = event.copy {
            view.selection = .init(anchorRow: copy.start.row, anchorColumn: copy.start.column,
                                   headRow: copy.end.row, headColumn: copy.end.column)
            #expect(view.selectedText == copy.text)
        }
    }
}

/// Exercise UIKit's committed text, paste, delete, Return and hardware chord paths as a
/// person would. Several recorded shell commands combine a typed string and Return.
@MainActor
private func performRecordedInput(_ input: Terminal.Input, in view: TerminalView) throws {
    switch input {
    case .text(let text):
        for character in text { view.phoneInput.insertText(character == "\r" ? "\n" : String(character)) }
    case .paste(let text): view.phoneInput.pasteText(text)
    case .key(.backspace, _): view.phoneInput.deleteBackward()
    case .key(.enter, _): view.phoneInput.insertText("\n")
    case .key(let key, let modifiers):
        let usage: UIKeyboardHIDUsage
        var characters = ""
        switch key {
        case .escape: usage = .keyboardEscape
        case .pageUp: usage = .keyboardPageUp
        case .pageDown: usage = .keyboardPageDown
        case .character("t"):
            usage = .keyboardT
            characters = "t"
        default:
            Issue.record("Unexpected recorded hardware key \(key)")
            return
        }
        let flags: UIKeyModifierFlags = modifiers.contains(.control) ? .control : []
        let (nativeKey, nativeModifiers) = try #require(PhoneTerminalInput.hardwareKey(usage, characters: characters, flags: flags))
        view.sendInput(.key(nativeKey, modifiers: nativeModifiers))
    case .pointer: Issue.record("Unexpected pointer event in typing workflow")
    }
}
#endif
