import Testing
import Thrush
@testable import ThrushUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Test func replacingDisplayedReplayPreservesCompositionFocusAndSingleCommit() throws {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 402, height: 420))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let grid = Terminal.Size(columns: 28, rows: 4)
    var before = Terminal(size: grid)
    _ = before.receive("old prompt$ ".utf8)
    var restored = Terminal(size: grid)
    _ = restored.receive("replayed line\r\nnew$ ".utf8)
    view.display(before)
    var writes: [[UInt8]] = []
    view.onInput = { writes.append(restored.encode($0)) }

    #if os(macOS)
    let input = try #require(view.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let nativeWindow = try #require(window as? NSWindow)
    view.layoutSubtreeIfNeeded()
    try #require(view.focusInput())
    let marked = NSRange(location: 1, length: 1)
    let unspecified = NSRange(location: NSNotFound, length: 0)
    input.setMarkedText("つば", selectedRange: marked, replacementRange: unspecified)
    #expect(nativeWindow.firstResponder === input)
    view.replaceDisplayedSnapshot(restored.snapshot(), receivedAt: nil)
    #expect(nativeWindow.firstResponder === input)
    #expect(input.markedRange() == NSRange(location: 0, length: 2))
    #expect(input.selectedRange() == marked)
    #expect(input.attributedSubstring(forProposedRange: input.markedRange(), actualRange: nil)?.string == "つば")
    #expect(writes.isEmpty)
    input.insertText("翼", replacementRange: unspecified)
    input.unmarkText()
    #else
    let nativeWindow = try #require(window as? UIWindow)
    nativeWindow.makeKeyAndVisible()
    view.layoutIfNeeded()
    try #require(view.focusInput())
    let input = view.phoneInput
    let marked = NSRange(location: 1, length: 1)
    input.setMarkedText("つば", selectedRange: marked)
    #expect(input.isFirstResponder)
    view.replaceDisplayedSnapshot(restored.snapshot(), receivedAt: nil)
    #expect(input.isFirstResponder)
    let markedRange = try #require(input.markedTextRange)
    #expect(input.text(in: markedRange) == "つば")
    #expect(input.selectedRange == marked)
    #expect(writes.isEmpty)
    input.insertText("翼")
    input.unmarkText()
    #endif
    #expect(writes == [Array("翼".utf8)])
}

@MainActor
@Test func ambiguousOneByteReplaySelectionClearsNativeCopyAndHandles() throws {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 402, height: 420))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let grid = Terminal.Size(columns: 20, rows: 6)
    var before = Terminal(size: grid)
    _ = before.receive("A\r\nx\r\nB\r\nA\r\nx\r\nB".utf8)
    view.display(before)
    var replay = Terminal(size: grid)
    _ = replay.receive("A\r\nx\r\nB\r\nlive".utf8)
    #if os(macOS)
    let input = try #require(view.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let copy = NSMenuItem(title: "Copy", action: #selector(MacTerminalInput.copy(_:)), keyEquivalent: "c")
    view.selectLine(row: 1)
    #expect(view.selectedText == "x" && input.validateMenuItem(copy))
    view.replaceDisplayedSnapshot(replay.snapshot(), receivedAt: nil)
    #expect(!input.validateMenuItem(copy))
    #else
    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    transcript.selectAccessibleLine(1)
    let copy = #selector(UIResponderStandardEditActions.copy(_:))
    #expect(view.selectedText == "x" && view.phoneInput.canPerformAction(copy, withSender: nil))
    let edit = try #require(transcript.interactions.compactMap { $0 as? UIEditMenuInteraction }.first)
    let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
    let handles = transcript.subviews.flatMap(\.subviews).filter { $0 is any UITextSelectionHandleView }
    #expect(handles.count == 2)
    view.replaceDisplayedSnapshot(replay.snapshot(), receivedAt: nil)
    #expect(!view.phoneInput.canPerformAction(copy, withSender: nil))
    #expect(handles.allSatisfy { $0.superview?.isHidden == true })
    #expect(edit.delegate?.editMenuInteraction?(edit, targetRectFor: configuration) == .null)
    #endif
    #expect(view.selection == nil)
}
