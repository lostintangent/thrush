#if os(iOS)
import UIKit

/// UIKit supplies the handle shapes and edit menu. Their geometry comes from the same
/// terminal cells as Metal's selection, including the second column of a wide character.
@MainActor
final class PhoneSelectionControls: NSObject, UITextSelectionDisplayInteractionDelegate, @MainActor UIEditMenuInteractionDelegate {
    private unowned let transcript: PhoneTranscriptView
    private var terminal: TerminalView { transcript.terminal }
    private lazy var menu = UIEditMenuInteraction(delegate: self)
    private var handles: [UIView & UITextSelectionHandleView] = []
    private var visibleButtons: [HandleTarget] = []
    private var active = false
    private var menuVisible = false
    private var lastSelection: TerminalView.Selection?
    private var movingStart = false
    private var dragOffset: CGPoint = .zero

    init(transcript: PhoneTranscriptView) {
        self.transcript = transcript
        super.init()
        transcript.addInteraction(menu)
    }

    func beginSelection() {
        active = true
        dismissMenu()
        if handles.isEmpty {
            // Obtain UIKit's standard selection handles for the same text input context as
            // the keyboard. Their positions track terminal cells rather than shaped text.
            let display = UITextSelectionDisplayInteraction(textInput: terminal.phoneInput, delegate: self)
            handles = display.handleViews
            for (index, handle) in handles.prefix(2).enumerated() {
                let target = HandleTarget()
                target.isAccessibilityElement = false
                target.accessibilityElementsHidden = true
                handle.direction = index == 0 ? .leading : .trailing
                handle.isUserInteractionEnabled = false
                handle.tintColor = nil  // Inherit the transcript's tint; the input's idle caret is clear.
                target.addSubview(handle)
                target.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
                transcript.addSubview(target)
                visibleButtons.append(target)
            }
        }
        if terminal.selection != nil { update() }
    }

    func update() {
        guard active else { return }
        guard let selection = terminal.selection, let snapshot = terminal.snapshot else {
            active = false
            visibleButtons.forEach { $0.isHidden = true }
            dismissMenu()
            return
        }
        var first = (selection.anchorRow, selection.anchorColumn)
        var last = (selection.headRow, selection.headColumn)
        if last < first { swap(&first, &last) }
        for (index, target) in visibleButtons.enumerated() {
            let (row, col) = index == 0 ? first : last
            guard snapshot.rows.indices.contains(row), (0..<snapshot.size.columns).contains(col) else {
                target.isHidden = true
                continue
            }
            let line = snapshot.rows[row]
            var column = col
            if column > 0, line[column - 1].width == 2 { column -= 1 }
            let boundary = index == 0 ? column : min(snapshot.size.columns, column + max(1, line[column].width))
            let cell = terminal.cellRect(row: row, column: min(boundary, snapshot.size.columns - 1))
            let x = boundary == snapshot.size.columns ? cell.maxX : cell.minX
            let edge = CGRect(x: x, y: cell.minY, width: 0, height: cell.height)
            let handle = handles[index]
            let frame = handle.preferredFrame(for: edge)
            let hit = CGRect(x: frame.midX - 22, y: frame.midY - 22, width: 44, height: 44)
            target.isHidden = false
            target.frame = hit
            handle.frame = frame.offsetBy(dx: -hit.minX, dy: -hit.minY)
            target.edge = CGPoint(x: x, y: cell.midY)
        }
        if menuVisible {
            menu.updateVisibleMenuPosition(animated: false)
            if lastSelection != selection { menu.reloadVisibleMenu() }
        }
        lastSelection = selection
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: transcript)
        guard let target = gesture.view as? HandleTarget else { return }
        switch gesture.state {
        case .began:
            dismissMenu()
            movingStart = target === visibleButtons.first
            dragOffset = CGPoint(x: target.edge.x - point.x, y: target.edge.y - point.y)
        case .changed, .ended:
            var edge = CGPoint(x: point.x + dragOffset.x, y: point.y + dragOffset.y)
            // The trailing handle is an insertion boundary immediately after the last cell.
            if !movingStart { edge.x -= 0.5 }
            guard let selection = terminal.selection, let cell = terminal.cell(at: edge) else { break }
            var low = (selection.anchorRow, selection.anchorColumn)
            var high = (selection.headRow, selection.headColumn)
            if high < low { swap(&low, &high) }
            let fixed = movingStart ? high : low
            movingStart = cell == fixed ? movingStart : cell < fixed
            terminal.selection = .init(anchorRow: fixed.0, anchorColumn: fixed.1,
                                       headRow: cell.row, headColumn: cell.column)
        default: break
        }
        if gesture.state == .ended { showMenu() }
    }

    /// A short selection can put both 44 pt hit targets under the same fingertip.
    /// Pick the nearer system handle so the trailing target cannot mask the leading one.
    func hitTarget(at point: CGPoint) -> UIView? {
        guard active else { return nil }
        let candidates = visibleButtons.filter { !$0.isHidden && $0.frame.contains(point) }
        return candidates.min { a, b in
            hypot(a.center.x - point.x, a.center.y - point.y) < hypot(b.center.x - point.x, b.center.y - point.y)
        }
    }

    var protectedRects: [CGRect] {
        guard active else { return [] }
        var rects = visibleButtons.filter { !$0.isHidden }.map(\.frame)
        if menuVisible, let selectedRect { rects.append(selectedRect) }
        return rects
    }

    func showMenu() {
        guard let rect = selectedRect else { return }
        menu.presentEditMenu(with: .init(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY)))
    }

    func dismissMenu() {
        menu.dismissMenu()
        menuVisible = false
    }

    private var selectedRect: CGRect? {
        guard let selection = terminal.selection, let snapshot = terminal.snapshot else { return nil }
        var rect = CGRect.null
        for row in snapshot.rows.indices {
            guard let columns = selection.columns(in: row, width: snapshot.size.columns) else { continue }
            rect = rect.union(terminal.cellRect(row: row, column: columns.lowerBound))
                .union(terminal.cellRect(row: row, column: columns.upperBound - 1))
        }
        return rect.isNull ? nil : rect.intersection(transcript.bounds)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        selectedRect ?? .null
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if terminal.selectedText != nil {
            actions.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                if let text = self?.terminal.selectedText { UIPasteboard.general.string = text }
            })
            actions.append(UIAction(title: "Select Line", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward"),
                                    attributes: .keepsMenuPresented) { [weak self] _ in
                guard let self, let selection = terminal.selection else { return }
                terminal.selectLine(row: selection.headRow)
            })
        }
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: "Paste", image: UIImage(systemName: "document.on.clipboard")) { [weak self] _ in
                self?.terminal.phoneInput.paste(nil)
            })
        }
        return UIMenu(children: actions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willPresentMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = true
        transcript.layoutLatest()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                             animator: any UIEditMenuInteractionAnimating) {
        menuVisible = false
        transcript.layoutLatest()
    }

    private final class HandleTarget: UIView {
        var edge: CGPoint = .zero
    }
}
#endif
