#if os(iOS)
import UIKit

/// Build an accessible line only when UIKit requests the reading order. Output and frame
/// timing remain independent of the length of the transcript when VoiceOver is idle.
@MainActor
final class PhoneTranscriptAccessibility {
    private struct LineID: Hashable {
        let generation: UInt64
        let occurrence: Int
    }

    private var rows: [LineID: UIAccessibilityElement] = [:]
    private var cached: [Any]?
    private var selectionElement: UIAccessibilityElement?

    func invalidate() { cached = nil }

    func elements(in view: PhoneTranscriptView, latest: UIButton) -> [Any] {
        if let cached { return cached }
        let terminal = view.terminal
        var result: [Any] = []
        var next: [LineID: UIAccessibilityElement] = [:]
        var occurrences: [UInt64: Int] = [:]
        if let snapshot = terminal.snapshot {
            var start = 0
            while start < snapshot.rows.count {
                var end = start
                while end + 1 < snapshot.rows.count && snapshot.rows[end + 1].isWrapped { end += 1 }
                let text = terminal.logicalLineText(row: start)
                if !text.isEmpty {
                    let generation = snapshot.rows[start].generation
                    let id = LineID(generation: generation, occurrence: occurrences[generation, default: 0])
                    occurrences[generation, default: 0] += 1
                    let element = rows[id] ?? UIAccessibilityElement(accessibilityContainer: view)
                    element.accessibilityLabel = text
                    element.accessibilityTraits = .staticText
                    element.accessibilityFrameInContainerSpace = terminal.cellRect(row: start, column: 0)
                        .union(terminal.cellRect(row: end, column: snapshot.size.columns - 1))
                    let row = start
                    element.accessibilityCustomActions = [
                        UIAccessibilityCustomAction(name: "Select line") { [weak view] _ in
                            guard let view else { return false }
                            view.selectAccessibleLine(row)
                            return true
                        },
                    ]
                    if terminal.acceptsTerminalInput {
                        element.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: "Type in terminal") { [weak view] _ in
                            view?.terminal.focusInput() ?? false
                        })
                    }
                    next[id] = element
                    result.append(element)
                }
                start = end + 1
            }
        }
        if let selected = terminal.selectedText, !selected.isEmpty {
            let element = selectionElement ?? UIAccessibilityElement(accessibilityContainer: view)
            element.accessibilityLabel = "Selected text"
            element.accessibilityValue = selected
            element.accessibilityTraits = [.staticText, .selected]
            if let selection = terminal.selection {
                let endpoint = max(0, min(terminal.snapshot.map { $0.size.rows - 1 } ?? 0, selection.headRow))
                element.accessibilityFrameInContainerSpace = terminal.cellRect(row: endpoint, column: selection.headColumn)
            }
            element.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Copy") { [weak view] _ in
                    guard let value = view?.terminal.selectedText else { return false }
                    UIPasteboard.general.string = value
                    return true
                },
                UIAccessibilityCustomAction(name: "Clear selection") { [weak view] _ in
                    view?.terminal.selection = nil
                    return view != nil
                },
            ]
            selectionElement = element
            result.append(element)
        }
        if result.isEmpty {
            let element = EmptyTerminalElement(accessibilityContainer: view)
            element.accessibilityLabel = "Terminal"
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = view.bounds
            result.append(element)
        }
        rows = next
        if !latest.isHidden { result.append(latest) }
        cached = result
        return result
    }

    private final class EmptyTerminalElement: UIAccessibilityElement {
        override func accessibilityActivate() -> Bool {
            (accessibilityContainer as? PhoneTranscriptView)?.terminal.focusInput() ?? false
        }
    }
}
#endif
