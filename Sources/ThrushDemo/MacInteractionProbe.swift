#if os(macOS)
import AppKit
import ThrushUI

/// Exercise Cocoa's real first responder, text input client, accessibility text ranges and pasteboard.
@MainActor
struct NativeInteractionProbe {
    private let client: any NSTextInputClient
    private let surface: NSView
    private let clipboard: any MacTerminalClipboard
    private let unspecified = NSRange(location: NSNotFound, length: 0)

    init(view: TerminalView) throws {
        guard view.focusInput(), let surface = view.window?.firstResponder as? NSView,
              let client = surface as? any NSTextInputClient, let clipboard = surface as? any MacTerminalClipboard else {
            throw RenderBenchmark.Failure("The terminal's text input client could not receive focus.")
        }
        self.client = client
        self.surface = surface
        self.clipboard = clipboard
    }

    var transcript: String { surface.accessibilityValue() as? String ?? "" }
    var selection: String? {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        clipboard.copySelection(to: board)
        return board.string(forType: .string)
    }

    func mark(_ text: String) throws {
        client.setMarkedText(text, selectedRange: NSRange(location: 0, length: text.utf16.count), replacementRange: unspecified)
        guard client.hasMarkedText() else { throw RenderBenchmark.Failure("Missing local marked text.") }
    }

    func commit(_ text: String) throws {
        client.insertText(text, replacementRange: unspecified)
        client.unmarkText()
        guard !client.hasMarkedText() else { throw RenderBenchmark.Failure("The input client retained a committed mark.") }
    }

    func paste(_ text: String) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard board.setString(text, forType: .string) else { throw RenderBenchmark.Failure("Could not populate the pasteboard.") }
        clipboard.paste(from: board)
    }

    func select(_ range: NSRange, in fullText: String) throws {
        surface.setAccessibilitySelectedTextRange(range)
        guard surface.accessibilitySelectedTextRange() == range,
              surface.accessibilitySelectedText() == (fullText as NSString).substring(with: range) else {
            throw RenderBenchmark.Failure("VoiceOver and the terminal selection disagree.")
        }
    }

    func latest() throws {
        guard let action = surface.accessibilityCustomActions()?.first(where: { $0.name == "Return to latest output" }),
              action.handler?() == true else { throw RenderBenchmark.Failure("The Latest action is unavailable.") }
    }

    func readLine(_ row: Int) -> String? {
        surface.accessibilityString(for: surface.accessibilityRange(forLine: row))
    }
}
#endif
