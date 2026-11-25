#if os(macOS)
import AppKit
import ThrushCore

@MainActor
package protocol MacTerminalClipboard {
    func copySelection(to pasteboard: NSPasteboard)
    func paste(from pasteboard: NSPasteboard)
}

/// AppKit owns key interpretation and candidate windows. Only committed text leaves this responder.
@MainActor
final class MacTerminalInput: NSView, @MainActor NSTextInputClient, NSMenuItemValidation, MacTerminalClipboard {
    unowned let terminal: TerminalView
    private var marked = NSAttributedString()
    private var insertion = NSRange(location: 0, length: 0)
    private var preview: NSTextView?
    private var dragAnchor: (row: Int, column: Int)?
    private var initialSelection: TerminalView.Selection?
    private var clickCount = 0
    private var remoteButtons: Set<Int> = []
    private var wheelRemainder: CGFloat = 0
    private let history = MacHistoryScrollView()
    private let latest = MacLatestControl()
    private var scrollExtent = CGSize.zero
    private var syncingHistory = false
    private var previousCursor = CGRect.null
    private var accessibilityText: MacAccessibleText?
    private var readingCaret: MacAccessibleText.Caret?
    private var previousGeneration: UInt64?
    private var previousOffset: Int?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: terminal.bounds)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        history.frame = bounds
        history.autoresizingMask = [.width, .height]
        history.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(historyDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: history.contentView)
        addSubview(history)
        latest.onActivate = { [weak self] in self?.returnToLatest() }
        latest.isHidden = true
        addSubview(latest)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    func invalidateTranscriptCache() {
        previousGeneration = nil
        accessibilityText = nil
    }

    func refresh() {
        if let readingCaret, terminal.selection != nil
            || readingCaret.visibleRow(in: terminal.snapshot, historyOffset: terminal.historyOffset) == nil {
            self.readingCaret = nil
        }
        if !terminal.acceptsTerminalInput { discardComposition() }
        if previousGeneration != terminal.snapshot?.generation || previousOffset != terminal.historyOffset {
            accessibilityText = nil
            previousGeneration = terminal.snapshot?.generation
            previousOffset = terminal.historyOffset
            if window != nil, NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
        if !latest.isHidden { latest.apply(terminal.resolvedTheme) }
        let cursor = terminal.cursorRect
        if cursor != previousCursor || preview != nil {
            previousCursor = cursor
            layoutMarkedText()
            if window?.firstResponder === self { inputContext?.invalidateCharacterCoordinates() }
        }
        syncHistory()
    }

    func resetInteraction() {
        discardComposition()
        dragAnchor = nil
        initialSelection = nil
        remoteButtons.removeAll()
        wheelRemainder = 0
        refresh()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        terminal.inputFocusDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        discardComposition()
        guard super.resignFirstResponder() else { return false }
        terminal.inputFocusDidChange()
        return true
    }

    private func discardComposition() {
        guard hasMarkedText() else { return }
        clearMarkedText()
        inputContext?.discardMarkedText()
    }

    private func clearMarkedText() {
        marked = NSAttributedString()
        insertion = NSRange(location: 0, length: 0)
        preview?.removeFromSuperview()
        preview = nil
    }

    // MARK: - Hardware keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.contains(.command) else { super.keyDown(with: event); return }
        // Give the active input method its navigation, escape and confirmation keys.
        if !hasMarkedText() {
            let modifiers = Self.modifiers(flags)
            if let key = Self.specialKey(event.keyCode) {
                if modifiers == .shift, case .pageUp = key {
                    terminal.setHistoryOffset(terminal.historyOffset + (terminal.snapshot?.size.rows ?? 1))
                } else if modifiers == .shift, case .pageDown = key {
                    terminal.setHistoryOffset(terminal.historyOffset - (terminal.snapshot?.size.rows ?? 1))
                } else if terminal.acceptsTerminalInput {
                    terminal.sendInput(.key(key, modifiers: modifiers))
                }
                return
            }
            guard terminal.acceptsTerminalInput else { return }
            if flags.contains(.control), let text = event.charactersIgnoringModifiers, text.count == 1, let key = text.first {
                terminal.sendInput(.key(.character(key), modifiers: modifiers))
                return
            }
        }
        if terminal.acceptsTerminalInput { interpretKeyEvents([event]) }
    }

    private static func specialKey(_ keyCode: UInt16) -> Terminal.Input.Key? {
        switch keyCode {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        case 36, 76: .enter
        case 48: .tab
        case 51: .backspace
        case 53: .escape
        case 115: .home
        case 116: .pageUp
        case 117: .delete
        case 119: .end
        case 121: .pageDown
        default: nil
        }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> Terminal.Input.Modifiers {
        var result: Terminal.Input.Modifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    override func doCommand(by selector: Selector) {
        guard terminal.acceptsTerminalInput else { return }
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)): terminal.sendInput(.key(.enter))
        case #selector(insertTab(_:)): terminal.sendInput(.key(.tab))
        case #selector(insertBacktab(_:)): terminal.sendInput(.key(.tab, modifiers: .shift))
        case #selector(deleteBackward(_:)): terminal.sendInput(.key(.backspace))
        case #selector(deleteForward(_:)): terminal.sendInput(.key(.delete))
        case #selector(moveLeft(_:)): terminal.sendInput(.key(.left))
        case #selector(moveRight(_:)): terminal.sendInput(.key(.right))
        case #selector(moveUp(_:)): terminal.sendInput(.key(.up))
        case #selector(moveDown(_:)): terminal.sendInput(.key(.down))
        case #selector(cancelOperation(_:)):
            if hasMarkedText() { discardComposition() } else { terminal.sendInput(.key(.escape)) }
        default: super.doCommand(by: selector)
        }
    }

    // MARK: - Text composition

    private func attributed(_ value: Any) -> NSAttributedString? {
        if let value = value as? NSAttributedString { return value }
        if let value = value as? String { return NSAttributedString(string: value) }
        return nil
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard terminal.acceptsTerminalInput, let text = attributed(string)?.string else { return }
        let commit: String
        if hasMarkedText(), let valid = bounded(replacementRange, to: marked.length) {
            commit = (marked.string as NSString).replacingCharacters(in: valid, with: text)
        } else {
            commit = text
        }
        clearMarkedText()
        if !commit.isEmpty { terminal.sendInput(.text(commit)) }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard terminal.acceptsTerminalInput, let text = attributed(string) else { return }
        let buffer = NSMutableAttributedString(attributedString: marked)
        let replacement = bounded(replacementRange, to: buffer.length) ?? NSRange(location: 0, length: buffer.length)
        buffer.replaceCharacters(in: replacement, with: text)
        guard buffer.length > 0 else { clearMarkedText(); return }
        marked = buffer
        let local = bounded(selectedRange, to: text.length) ?? NSRange(location: text.length, length: 0)
        insertion = NSRange(location: replacement.location + local.location, length: local.length)
        layoutMarkedText()
        inputContext?.invalidateCharacterCoordinates()
    }

    func unmarkText() {
        guard terminal.acceptsTerminalInput else { clearMarkedText(); return }
        guard hasMarkedText() else { return }
        let commit = marked.string
        clearMarkedText()
        terminal.sendInput(.text(commit))
    }

    func selectedRange() -> NSRange { insertion }
    func markedRange() -> NSRange { NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .glyphInfo]
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard hasMarkedText(), let valid = bounded(range, to: marked.length) else { return nil }
        actualRange?.pointee = valid
        return marked.attributedSubstring(from: valid)
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        if let preview, let valid = bounded(range, to: marked.length) {
            return preview.firstRect(forCharacterRange: valid, actualRange: actualRange)
        }
        actualRange?.pointee = NSRange(location: 0, length: 0)
        return window?.convertToScreen(convert(terminal.cursorRect, to: nil)) ?? .zero
    }

    func characterIndex(for point: NSPoint) -> Int { preview?.characterIndex(for: point) ?? 0 }

    // NSTextView supplies native shaping and candidate geometry for the transient marked string.
    private func layoutMarkedText() {
        guard hasMarkedText() else { return }
        let field: NSTextView
        if let preview { field = preview } else {
            field = MacPreeditView()
            field.isEditable = false
            field.isSelectable = false
            field.setAccessibilityElement(false)
            field.textContainerInset = .zero
            field.textContainer?.lineFragmentPadding = 0
            field.textContainer?.widthTracksTextView = false
            field.drawsBackground = true
            addSubview(field)
            preview = field
        }
        field.backgroundColor = NSColor(terminal: terminal.color(.background))
        let text = NSMutableAttributedString(attributedString: marked)
        let full = NSRange(location: 0, length: text.length)
        let font = NSFont.monospacedSystemFont(ofSize: terminal.fontSize ?? 14, weight: .regular)
        text.addAttributes([.font: font, .foregroundColor: NSColor(terminal: terminal.color(.foreground))], range: full)
        text.enumerateAttribute(.underlineStyle, in: full) { value, range, _ in
            if value == nil { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
        if insertion.length > 0 {
            text.addAttributes([.backgroundColor: NSColor.selectedTextBackgroundColor,
                                .foregroundColor: NSColor.selectedTextColor], range: insertion)
        }
        field.textStorage?.setAttributedString(text)
        let cell = terminal.cursorRect
        let width = min(max(1, bounds.width), max(cell.width, ceil(text.size().width) + 1))
        field.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        var height = cell.height
        if let container = field.textContainer, let manager = field.layoutManager {
            manager.ensureLayout(for: container)
            height = max(height, ceil(manager.usedRect(for: container).height))
        }
        field.frame = CGRect(x: max(0, min(cell.minX, bounds.maxX - width)),
                             y: max(0, min(cell.minY, bounds.maxY - height)), width: width, height: height)
    }

    // MARK: - Clipboard and edit menu

    @objc func copy(_ sender: Any?) { copySelection(to: .general) }

    func copySelection(to pasteboard: NSPasteboard) {
        guard let text = terminal.selectedText, !text.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) { paste(from: .general) }

    func paste(from pasteboard: NSPasteboard) {
        if terminal.acceptsTerminalInput, let text = pasteboard.string(forType: .string), !text.isEmpty {
            discardComposition()
            terminal.sendInput(.paste(text))
        }
    }

    override func selectAll(_ sender: Any?) {
        guard let size = terminal.snapshot?.size else { return }
        terminal.selection = .init(anchorRow: 0, anchorColumn: 0, headRow: size.rows - 1, headColumn: size.columns - 1)
        selectionDidChange()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)): terminal.selectedText?.isEmpty == false
        case #selector(paste(_:)): terminal.acceptsTerminalInput && NSPasteboard.general.availableType(from: [.string]) != nil
        case #selector(selectAll(_:)): terminal.snapshot != nil
        default: true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:))),
                                ("Select All", #selector(selectAll(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: - Pointer and selection

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if report(event, .press, .left) { remoteButtons.insert(0); return }
        guard let hit = terminal.cell(at: convert(event.locationInWindow, from: nil)) else { return }
        readingCaret = nil
        clickCount = event.clickCount
        if event.modifierFlags.contains(.shift), let existing = terminal.selection {
            dragAnchor = (existing.anchorRow, existing.anchorColumn)
            clickCount = 1
            terminal.selection = .init(anchorRow: existing.anchorRow, anchorColumn: existing.anchorColumn,
                                       headRow: hit.row, headColumn: hit.column)
        } else {
            dragAnchor = hit
            switch clickCount {
            case 1: terminal.selection = nil
            case 2: terminal.selectWord(row: hit.row, column: hit.column)
            default: terminal.selectLine(row: hit.row)
            }
        }
        initialSelection = terminal.selection
        selectionDidChange()
    }

    override func mouseDragged(with event: NSEvent) {
        if remoteButtons.contains(0) { _ = report(event, .move, .left); return }
        guard let dragAnchor, let hit = terminal.cell(at: convert(event.locationInWindow, from: nil)) else { return }
        if clickCount > 1, let initialSelection {
            if clickCount == 2 { terminal.selectWord(row: hit.row, column: hit.column) }
            else { terminal.selectLine(row: hit.row) }
            if let extent = terminal.selection {
                if (hit.row, hit.column) < dragAnchor {
                    terminal.selection = .init(anchorRow: initialSelection.headRow, anchorColumn: initialSelection.headColumn,
                                               headRow: extent.anchorRow, headColumn: extent.anchorColumn)
                } else {
                    terminal.selection = .init(anchorRow: initialSelection.anchorRow, anchorColumn: initialSelection.anchorColumn,
                                               headRow: extent.headRow, headColumn: extent.headColumn)
                }
            }
        } else {
            terminal.selection = .init(anchorRow: dragAnchor.row, anchorColumn: dragAnchor.column,
                                       headRow: hit.row, headColumn: hit.column)
        }
        selectionDidChange()
    }

    override func mouseUp(with event: NSEvent) {
        if remoteButtons.remove(0) != nil { _ = report(event, .release, .left) }
        dragAnchor = nil
        initialSelection = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        if report(event, .press, .right) { remoteButtons.insert(1) }
        else { super.rightMouseDown(with: event) }
    }
    override func rightMouseDragged(with event: NSEvent) {
        if remoteButtons.contains(1) { _ = report(event, .move, .right) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if remoteButtons.remove(1) != nil { _ = report(event, .release, .right) }
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2, report(event, .press, .middle) { remoteButtons.insert(2) }
        else { super.otherMouseDown(with: event) }
    }
    override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, remoteButtons.contains(2) { _ = report(event, .move, .middle) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, remoteButtons.remove(2) != nil { _ = report(event, .release, .middle) }
    }
    override func mouseMoved(with event: NSEvent) { _ = report(event, .move, .none) }

    override func updateTrackingAreas() {
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    private func report(_ event: NSEvent, _ action: Terminal.Input.Pointer.Action,
                        _ button: Terminal.Input.Pointer.Button) -> Bool {
        let flags = Self.modifiers(event.modifierFlags)
        guard let hit = terminal.cell(at: convert(event.locationInWindow, from: nil)) else { return false }
        return terminal.reportPointer(action, button: button, row: hit.row, column: hit.column,
                                      modifiers: flags)
    }

    // MARK: - History

    override func scrollWheel(with event: NSEvent) {
        if terminal.isPointerReporting, !event.modifierFlags.contains(.shift) {
            if event.phase.contains(.began) { wheelRemainder = 0 }
            let divisor = event.hasPreciseScrollingDeltas ? max(1, terminal.cellRect(row: 0, column: 0).height) : 1
            wheelRemainder += event.scrollingDeltaY / divisor
            let steps = Int(wheelRemainder)
            wheelRemainder -= CGFloat(steps)
            for _ in 0..<min(64, abs(steps)) { _ = report(event, .press, steps > 0 ? .wheelUp : .wheelDown) }
            return
        }
        wheelRemainder = 0
        if terminal.historyCount > 0 { history.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }

    private func selectionDidChange() {
        NSAccessibility.post(element: self, notification: .selectedTextChanged)
    }

    @objc private func returnToLatest() {
        terminal.setHistoryOffset(0)
        window?.makeFirstResponder(self)
    }

    private func syncHistory() {
        guard let document = history.documentView else { return }
        let count = terminal.historyCount
        let rowHeight = max(1, terminal.cellRect(row: 0, column: 0).height)
        let visible = history.contentView.bounds.size
        let extent = CGSize(width: visible.width, height: visible.height + CGFloat(count) * rowHeight)
        let offset = terminal.historyOffset
        syncingHistory = true
        defer { syncingHistory = false }
        let sizeChanged = extent != scrollExtent
        if sizeChanged {
            document.setFrameSize(extent)
            scrollExtent = extent
        }
        let desiredY = CGFloat(count - offset) * rowHeight
        if sizeChanged || abs(history.contentView.bounds.minY - desiredY) >= rowHeight * 0.51 {
            history.contentView.scroll(to: NSPoint(x: 0, y: desiredY))
            history.reflectScrolledClipView(history.contentView)
        }
        if latest.isHidden, offset > 0 { latest.apply(terminal.resolvedTheme) }
        latest.isHidden = offset == 0
        latest.frame = CGRect(x: max(0, bounds.maxX - 120), y: max(0, bounds.maxY - terminal.noticeBottomInset - 56), width: 104, height: 44)
    }

    @objc private func historyDidScroll() {
        guard !syncingHistory else { return }
        let count = terminal.historyCount
        let rowHeight = max(1, terminal.cellRect(row: 0, column: 0).height)
        let offset = min(count, max(0, count - Int((history.contentView.bounds.minY / rowHeight).rounded())))
        if offset != terminal.historyOffset { terminal.setHistoryOffset(offset) }
    }

    // MARK: - Accessibility

    // VoiceOver addresses UTF-16 ranges. The map is built on the first accessibility query
    // for a displayed generation, and is reused as the user navigates by line or character.
    private var transcript: MacAccessibleText {
        if let accessibilityText { return accessibilityText }
        let text = MacAccessibleText(snapshot: terminal.snapshot) { terminal.text(in: $0, spoken: true) }
        accessibilityText = text
        return text
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard terminal.historyOffset > 0 else { return nil }
        return [NSAccessibilityCustomAction(name: "Return to latest output") { [weak self] in
            guard let self else { return false }
            returnToLatest()
            return true
        }]
    }

    override func accessibilityValue() -> Any? { transcript.string }
    override func accessibilityNumberOfCharacters() -> Int { transcript.string.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: transcript.string.length) }
    override func accessibilitySelectedText() -> String? { terminal.spokenSelectedText ?? "" }
    override func accessibilitySelectedTextRange() -> NSRange {
        if let selection = terminal.selection { return transcript.range(for: selection) }
        guard let snapshot = terminal.snapshot else { return NSRange(location: 0, length: 0) }
        if let readingCaret, let row = readingCaret.visibleRow(in: snapshot, historyOffset: terminal.historyOffset) {
            let line = transcript.lines[row].range
            if readingCaret.utf16Offset <= line.length {
                return NSRange(location: line.location + readingCaret.utf16Offset, length: 0)
            }
        }
        return NSRange(location: transcript.range(row: snapshot.cursorRow, column: snapshot.cursorColumn).location, length: 0)
    }

    override func setAccessibilitySelectedTextRange(_ range: NSRange) {
        guard let valid = bounded(range, to: transcript.string.length) else { return }
        if valid.length == 0, let snapshot = terminal.snapshot {
            readingCaret = MacAccessibleText.Caret(index: valid.location, text: transcript, snapshot: snapshot,
                                                   historyOffset: terminal.historyOffset)
        } else {
            readingCaret = nil
        }
        terminal.selection = transcript.selection(for: valid)
        selectionDidChange()
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        accessibilityLine(for: accessibilitySelectedTextRange().location)
    }
    override func accessibilityLine(for index: Int) -> Int { transcript.line(for: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard transcript.lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        return transcript.lines[line].range
    }
    override func accessibilityString(for range: NSRange) -> String? {
        bounded(range, to: transcript.string.length).map { transcript.string.substring(with: $0) }
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map(NSAttributedString.init(string:))
    }
    override func accessibilityRange(for index: Int) -> NSRange {
        guard index >= 0, index < transcript.string.length else { return NSRange(location: NSNotFound, length: 0) }
        return transcript.string.rangeOfComposedCharacterSequence(at: index)
    }
    override func accessibilityRange(for point: NSPoint) -> NSRange {
        guard let window, let hit = terminal.cell(at: convert(window.convertPoint(fromScreen: point), from: nil)) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return transcript.range(row: hit.row, column: hit.column)
    }
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window, let range = bounded(range, to: transcript.string.length) else { return .zero }
        let start = transcript.position(at: range.location)
        let end = transcript.position(at: max(range.location, NSMaxRange(range) - 1), trailing: range.length > 0)
        var rect = terminal.cellRect(row: start.row, column: start.column)
        rect = rect.union(terminal.cellRect(row: end.row, column: end.column))
        if end.row > start.row, let width = terminal.snapshot?.size.columns {
            rect = rect.union(terminal.cellRect(row: start.row, column: width - 1))
            rect = rect.union(terminal.cellRect(row: end.row, column: 0))
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

}

private final class MacPreeditView: NSTextView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class MacHistoryScrollView: NSScrollView {
    private final class ExtentView: NSView { override var isFlipped: Bool { true } }
    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        verticalScroller?.controlSize = .small
        autohidesScrollers = true
        borderType = .noBorder
        verticalScrollElasticity = .none
        documentView = ExtentView()
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), let scroller = verticalScroller,
              hit === scroller || hit.isDescendant(of: scroller) else { return nil }
        return hit
    }
}

private extension NSColor {
    convenience init(terminal color: Terminal.RGB) {
        self.init(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                  blue: CGFloat(color.blue) / 255, alpha: 1)
    }
}

private func bounded(_ range: NSRange, to length: Int) -> NSRange? {
    guard range.location >= 0, range.location <= length, range.length >= 0 else { return nil }
    return NSRange(location: range.location, length: min(length - range.location, range.length))
}
#endif
