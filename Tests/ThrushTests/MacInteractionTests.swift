#if os(macOS)
import AppKit
import Testing
import ThrushCore
@testable import Thrush

@MainActor
private struct MacInputFixture {
    let view: TerminalView
    let window: NSWindow
    let input: MacTerminalInput

    init() throws {
        _ = NSApplication.shared
        view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        window = NSWindow(contentRect: view.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        input = try #require(view.subviews.compactMap { $0 as? MacTerminalInput }.first)
        try #require(view.focusInput())
    }

    func key(_ code: UInt16, characters: String, flags: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                 characters: characters, charactersIgnoringModifiers: characters,
                                                 isARepeat: false, keyCode: code))
        input.keyDown(with: event)
    }

    func mouse(_ type: NSEvent.EventType, row: Int, column: Int, clicks: Int = 1,
               flags: NSEvent.ModifierFlags = []) throws {
        let cell = view.cellRect(row: row, column: column)
        let position = input.convert(CGPoint(x: cell.midX, y: cell.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: position, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: clicks, pressure: 1))
        switch type {
        case .leftMouseDown: input.mouseDown(with: event)
        case .leftMouseDragged: input.mouseDragged(with: event)
        case .leftMouseUp: input.mouseUp(with: event)
        default: Issue.record("Unhandled event")
        }
    }

}

@MainActor
@Test func appKitKeepsCompositionLocalAndCommitsExactlyOnce() throws {
    let host = try MacInputFixture()
    let terminal = Terminal(size: .init(columns: 20, rows: 4))
    host.view.display(terminal)
    var writes = [[UInt8]]()
    host.view.onInput = { writes.append(terminal.encode($0)) }
    let unspecified = NSRange(location: NSNotFound, length: 0)
    host.input.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: unspecified)
    host.input.setMarkedText("日本", selectedRange: NSRange(location: 1, length: 1), replacementRange: unspecified)
    #expect(host.input.markedRange() == NSRange(location: 0, length: 2))
    #expect(host.input.selectedRange() == NSRange(location: 1, length: 1))
    #expect(host.input.attributedSubstring(forProposedRange: NSRange(location: 0, length: 2),
                                           actualRange: nil)?.string == "日本")
    #expect(writes.isEmpty)
    let candidate = host.input.firstRect(forCharacterRange: host.input.selectedRange(), actualRange: nil)
    #expect(candidate.height > 0)
    host.input.insertText("日本語", replacementRange: unspecified)
    host.input.unmarkText()
    #expect(writes == [Array("日本語".utf8)])
    #expect(!host.input.hasMarkedText())

    host.input.setMarkedText("🐦", selectedRange: NSRange(location: 2, length: 0), replacementRange: unspecified)
    host.view.cancelPendingInput()
    host.input.unmarkText()
    #expect(writes.count == 1)
}

@MainActor
@Test func appKitFrozenPaneAllowsCopyAndDropsPendingComposition() throws {
    let host = try MacInputFixture()
    var shell = Terminal(size: .init(columns: 20, rows: 4))
    _ = shell.receive("final output".utf8)
    host.view.display(shell)
    var writes: [Terminal.Input] = []
    host.view.onInput = { writes.append($0) }
    let unspecified = NSRange(location: NSNotFound, length: 0)
    let insertion = NSRange(location: 1, length: 0)
    host.input.setMarkedText("日", selectedRange: insertion, replacementRange: unspecified)
    host.view.setInputAvailability(.blocked, dismissKeyboard: true)
    host.input.setMarkedText("翼", selectedRange: insertion, replacementRange: unspecified)
    host.input.insertText("鳥", replacementRange: unspecified)
    host.input.unmarkText()
    try host.key(36, characters: "\r")
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("explicit paste", forType: .string)
    host.input.paste(from: board)
    #expect(!host.input.hasMarkedText())
    #expect(writes.isEmpty)

    host.input.setAccessibilitySelectedTextRange(.init(location: 0, length: 12))
    host.input.copySelection(to: board)
    #expect(board.string(forType: .string) == "final output")
}

@MainActor
@Test func appKitKeysAndPasteUseCurrentTerminalModes() throws {
    let host = try MacInputFixture()
    var terminal = Terminal(size: .init(columns: 20, rows: 4))
    host.view.display(terminal)
    var writes = [[UInt8]]()
    host.view.onInput = { writes.append(terminal.encode($0)) }
    try host.key(126, characters: "\u{F700}")
    _ = terminal.receive("\u{1b}[?1h\u{1b}[?2004h".utf8)
    try host.key(126, characters: "\u{F700}")
    try host.key(124, characters: "\u{F703}", flags: [.control, .shift])
    try host.key(17, characters: "t", flags: [.control])
    try host.key(48, characters: "\t", flags: [.shift])
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("one\ntwo", forType: .string)
    host.input.paste(from: board)
    #expect(writes == ["\u{1b}[A", "\u{1b}OA", "\u{1b}[1;6C", "\u{14}", "\u{1b}[Z",
                       "\u{1b}[200~one\rtwo\u{1b}[201~"].map { Array($0.utf8) })
}

@MainActor
@Test func appKitVoiceOverAndCopyUseTheDisplayedCells() throws {
    let host = try MacInputFixture()
    var terminal = Terminal(size: .init(columns: 6, rows: 4))
    _ = terminal.receive("A翼🐦Zspill\r\nKnown".utf8)
    host.view.display(terminal)
    let known = host.input.accessibilityRange(forLine: 2)
    #expect(host.input.accessibilityString(for: known) == "Known\n")
    #expect(host.input.accessibilityLine(for: known.location) == 2)
    #expect(host.input.accessibilityValue() as? String == "A翼🐦Zspill\nKnown\n")
    let desired = NSRange(location: 1, length: 9)
    host.input.setAccessibilitySelectedTextRange(desired)
    #expect(host.input.accessibilitySelectedText() == "翼🐦Zspill")
    #expect(host.input.accessibilitySelectedTextRange() == desired)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    host.input.copySelection(to: board)
    #expect(board.string(forType: .string) == "翼🐦Zspill")

    // An inclusive selection of the emoji continuation still selects both UTF-16 code units.
    host.view.selection = .init(anchorRow: 0, anchorColumn: 4, headRow: 0, headColumn: 4)
    #expect(host.input.accessibilitySelectedTextRange() == NSRange(location: 2, length: 2))
}

@MainActor
@Test func appKitVoiceOverReadsConcealedTextAsBlankAndCopyKeepsIt() throws {
    let host = try MacInputFixture()
    var terminal = Terminal(size: .init(columns: 12, rows: 2))
    _ = terminal.receive("pw \u{1B}[8ms🐦cret\u{1B}[28m!".utf8)
    host.view.display(terminal)
    let blank = String(repeating: " ", count: "s🐦cret".utf16.count)
    #expect(host.input.accessibilityValue() as? String == "pw \(blank)!\n")
    host.view.selection = .init(anchorRow: 0, anchorColumn: 3, headRow: 0, headColumn: 9)
    #expect(host.input.accessibilitySelectedText() == blank)
    #expect(host.input.accessibilitySelectedTextRange() == NSRange(location: 3, length: blank.utf16.count))
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    host.input.copySelection(to: board)
    #expect(board.string(forType: .string) == "s🐦cret")
}

@MainActor
@Test func appKitKeepsACollapsedAccessibilityCaretIndependentOfTheShell() throws {
    let host = try MacInputFixture()
    var shell = Terminal(size: .init(columns: 30, rows: 4))
    _ = shell.receive("top\r\nRead 🐦 here\r\nPrompt % ".utf8)
    host.view.display(shell)
    var writes: [Terminal.Input] = []
    host.view.onInput = { writes.append($0) }

    host.input.setAccessibilitySelectedTextRange(.init(location: 10, length: 0))
    #expect(host.input.accessibilitySelectedTextRange() == NSRange(location: 9, length: 0))
    let caret = NSRange(location: 11, length: 0) // Just after the two-unit bird.
    host.input.setAccessibilitySelectedTextRange(caret)
    #expect(host.input.accessibilitySelectedTextRange() == caret)
    #expect(host.input.accessibilityInsertionPointLineNumber() == 1)
    #expect(host.input.accessibilitySelectedText() == "")
    #expect(host.view.selection == nil)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString("keep", forType: .string)
    host.input.copySelection(to: board)
    #expect(board.string(forType: .string) == "keep")

    _ = shell.receive("\u{1B}[1;1Hlonger title\u{1B}[3;10Hnew output".utf8)
    host.view.display(shell)
    let updated = NSRange(location: caret.location + 9, length: 0)
    #expect(host.input.accessibilitySelectedTextRange() == updated)
    #expect(host.input.accessibilityInsertionPointLineNumber() == 1)

    let end = NSRange(location: host.input.accessibilityNumberOfCharacters(), length: 0)
    host.input.setAccessibilitySelectedTextRange(end)
    #expect(host.input.accessibilitySelectedTextRange() == end)
    #expect(host.input.accessibilityInsertionPointLineNumber() == 3)

    host.input.setAccessibilitySelectedTextRange(updated)
    host.view.replaceDisplayedSnapshot(shell.snapshot(), receivedAt: nil)
    #expect(host.input.accessibilitySelectedTextRange() == updated)

    let word = NSRange(location: updated.location + 1, length: 4)
    host.input.setAccessibilitySelectedTextRange(word)
    #expect(host.input.accessibilitySelectedTextRange() == word)
    #expect(host.input.accessibilitySelectedText() == "here")
    host.input.copySelection(to: board)
    #expect(board.string(forType: .string) == "here")

    host.input.setAccessibilitySelectedTextRange(updated)
    _ = shell.receive("\u{1B}[2;1H\u{1B}[2Kremoved\u{1B}[3;1H".utf8)
    host.view.display(shell)
    #expect(host.input.accessibilitySelectedTextRange().location == host.input.accessibilityRange(forLine: 2).location)
    host.input.setAccessibilitySelectedTextRange(.init(location: 1, length: 0))
    host.view.reset()
    host.view.display(shell)
    #expect(host.input.accessibilityInsertionPointLineNumber() == 2)
    #expect(writes.isEmpty)
}

@MainActor
@Test func appKitReadingCaretFollowsItsRowWhileItRemainsVisible() throws {
    let host = try MacInputFixture()
    var shell = Terminal(size: .init(columns: 20, rows: 3))
    _ = shell.receive("First\r\nReading\r\nLast".utf8)
    host.view.display(shell)
    host.input.setAccessibilitySelectedTextRange(.init(location: 8, length: 0))
    _ = shell.receive("\r\nNew".utf8)
    host.view.display(shell)
    #expect(host.input.accessibilitySelectedTextRange() == NSRange(location: 2, length: 0))
    #expect(host.input.accessibilityInsertionPointLineNumber() == 0)
    _ = shell.receive("\r\nNewest".utf8)
    host.view.display(shell)
    #expect(host.input.accessibilityInsertionPointLineNumber() == 2)
}

@MainActor
@Test func appKitSelectsWrappedWordsAndHandsReportedDragsToTheShell() throws {
    let host = try MacInputFixture()
    var terminal = Terminal(size: .init(columns: 8, rows: 4))
    _ = terminal.receive("Read a wrapped word".utf8)
    host.view.display(terminal)
    try host.mouse(.leftMouseDown, row: 0, column: 7, clicks: 2)
    #expect(host.view.selectedText == "wrapped")
    try host.mouse(.leftMouseDown, row: 1, column: 4, clicks: 3)
    #expect(host.view.selectedText == "Read a wrapped word")
    try host.mouse(.leftMouseDown, row: 0, column: 5)
    try host.mouse(.leftMouseDragged, row: 1, column: 3)
    try host.mouse(.leftMouseUp, row: 1, column: 3)
    #expect(host.view.selectedText == "a wrapp")

    _ = terminal.receive("\u{1b}[?1002h\u{1b}[?1006h".utf8)
    host.view.display(terminal)
    var writes = [[UInt8]]()
    host.view.onInput = { writes.append(terminal.encode($0)) }
    try host.mouse(.leftMouseDown, row: 1, column: 2)
    try host.mouse(.leftMouseDragged, row: 1, column: 3)
    try host.mouse(.leftMouseUp, row: 1, column: 3, flags: .shift)
    #expect(writes == ["\u{1b}[<0;3;2M", "\u{1b}[<32;4;2M", "\u{1b}[<4;4;2m"].map { Array($0.utf8) })
    try host.mouse(.leftMouseDown, row: 2, column: 0, flags: .shift)
    try host.mouse(.leftMouseUp, row: 2, column: 0)
    #expect(writes.count == 3)
}

@MainActor
@Test func appKitHistoryKeepsTheReadingLineUntilLatestIsActivated() throws {
    let host = try MacInputFixture()
    var terminal = Terminal(size: .init(columns: 12, rows: 4))
    _ = terminal.receive((1...10).map { "Line \($0)" }.joined(separator: "\r\n").utf8)
    host.view.display(terminal)
    try host.key(116, characters: "\u{F72C}", flags: .shift)
    #expect(host.view.historyOffset == 4)
    let first = host.input.accessibilityString(for: host.input.accessibilityRange(forLine: 0))
    #expect(first == "Line 3\n")
    _ = terminal.receive("\r\nLine 11".utf8)
    host.view.display(terminal)
    #expect(host.input.accessibilityString(for: host.input.accessibilityRange(forLine: 0)) == first)
    let action = try #require(host.input.accessibilityCustomActions()?.first)
    #expect(action.handler?() == true)
    #expect(host.view.historyOffset == 0)
    host.view.setHistoryOffset(2)
    let target = try #require(host.input.subviews.compactMap { $0 as? MacLatestControl }.first)
    let button = try #require(target.subviews.compactMap { $0 as? NSButton }.first)
    #expect(target.bounds.size == CGSize(width: 104, height: 44))
    #expect(button.frame.size == CGSize(width: 104, height: 36))
    #expect(button.borderShape == .capsule)
    button.performClick(nil)
    #expect(host.view.historyOffset == 0 && target.isHidden)
    #expect(host.input.accessibilityString(for: host.input.accessibilityRange(forLine: 0)) == "Line 8\n")
}
#endif
