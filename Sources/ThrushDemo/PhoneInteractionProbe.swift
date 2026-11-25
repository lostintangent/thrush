#if os(iOS)
import Thrush
import UIKit

/// Drive the system text client, accessible output and keyboard edit path of the packaged viewport.
@MainActor
struct NativeInteractionProbe {
    private struct Failure: Error, CustomStringConvertible { let description: String }
    private let view: TerminalView
    private let input: UITextView
    private let reading: UIView

    init(view: TerminalView) throws {
        guard let input = view.subviews.compactMap({ $0 as? UITextView }).first,
              let reading = view.subviews.first(where: { !($0 is UITextView) && $0.accessibilityElements != nil }) else {
            throw Failure(description: "The iPhone terminal is missing its native input or accessible transcript.")
        }
        self.view = view
        self.input = input
        self.reading = reading
    }

    func mark(_ text: String) throws {
        input.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0))
        guard input.markedTextRange != nil else { throw Failure(description: "UIKit did not retain the marked text.") }
    }

    func commit(_ text: String) throws {
        input.insertText(text)
        input.unmarkText()
        guard input.markedTextRange == nil, input.text.isEmpty else {
            throw Failure(description: "The native text client retained its committed input.")
        }
    }

    func paste(_ text: String) throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = text
        guard board.string == text else { throw Failure(description: "The app could not populate a private pasteboard.") }
        view.paste(from: board)
    }

    private var lines: [UIAccessibilityElement] {
        (reading.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
            .filter { $0.accessibilityTraits.contains(.staticText) && !$0.accessibilityTraits.contains(.selected) }
    }

    func activateTyping() -> Bool {
        guard let action = lines.first?.accessibilityCustomActions?.first(where: { $0.name == "Type in terminal" }) else {
            return false
        }
        return action.actionHandler?(action) == true
    }

    var transcript: String { lines.compactMap(\.accessibilityLabel).joined(separator: "\n") }

    var selection: String? {
        (reading.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
            .first(where: { $0.accessibilityTraits.contains(.selected) })?.accessibilityValue
    }

    func select(_ range: NSRange, in fullText: String) throws {
        guard let target = Range(range, in: fullText), range.length > 0 else {
            throw Failure(description: "The requested selection has no text.")
        }
        var start = 0
        for line in lines {
            let label = line.accessibilityLabel ?? ""
            let length = label.utf16.count
            defer { start += length + 1 }
            guard range.location >= start, NSMaxRange(range) <= start + length else { continue }
            let relative = NSRange(location: range.location - start, length: range.length)
            guard let local = Range(relative, in: label),
                  let action = line.accessibilityCustomActions?.first(where: { $0.name == "Select line" }),
                  action.actionHandler?(action) == true, let whole = view.selection,
                  let width = view.gridSize?.columns else { break }
            // The benchmark's prefix is the ASCII shell prompt. The selected span can contain wide
            // or combining characters. UIKit's line selection already found its true cell endpoints.
            let prefix = label[..<local.lowerBound], suffix = label[local.upperBound...]
            guard prefix.utf8.allSatisfy({ (32...126).contains($0) }),
                  suffix.utf8.allSatisfy({ (32...126).contains($0) }) else { break }
            let first = whole.anchorRow * width + whole.anchorColumn + prefix.utf8.count
            let last = whole.headRow * width + whole.headColumn - suffix.utf8.count
            guard first >= 0, last >= first else { break }
            view.selection = .init(anchorRow: first / width, anchorColumn: first % width,
                                   headRow: last / width, headColumn: last % width)
            guard selection == String(fullText[target]) else { break }
            return
        }
        throw Failure(description: "The accessible selection did not match the wrapped terminal text.")
    }

    func latest() throws {
        guard let button = (reading.accessibilityElements ?? []).compactMap({ $0 as? UIButton })
            .first(where: { $0.accessibilityIdentifier == "terminal.latest" }) else {
            throw Failure(description: "Latest was unavailable in history.")
        }
        button.sendActions(for: .touchUpInside)
    }

    func readLine(_ row: Int) -> String? {
        let visible = lines
        return visible.indices.contains(row) ? visible[row].accessibilityLabel : nil
    }
}
#endif
