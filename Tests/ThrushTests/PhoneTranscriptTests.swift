#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
import UIKit

/// Read the same logical line through the accessible container and the edit selection.
@MainActor
@Test func phoneReadsAndSelectsSoftWrappedTextAtCellBoundaries() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    var terminal = Terminal(size: .init(columns: 8, rows: 5))
    _ = terminal.receive("Build comp".utf8)
    _ = terminal.receive("lete.\r\nA翼🐦Z".utf8)
    view.display(terminal)

    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    let lines = try #require(transcript.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement })
    #expect(lines.map(\.accessibilityLabel) == ["Build complete.", "A翼🐦Z"])
    #expect(lines[0].accessibilityFrameInContainerSpace.height == view.cellRect(row: 0, column: 0).height * 2)
    transcript.selectAccessibleLine(1)
    #expect(view.selectedText == "Build complete.")
    let selected = try #require(transcript.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
        .first(where: { $0.accessibilityTraits.contains(.selected) }))
    #expect(selected.accessibilityValue == view.selectedText)
    #expect(selected.accessibilityCustomActions?.map(\.name) == ["Copy", "Clear selection"])

    let handles = transcript.subviews.flatMap(\.subviews).filter { $0 is any UITextSelectionHandleView }
    #expect(handles.count == 2)
    #expect(handles.allSatisfy { !$0.frame.isEmpty && !$0.isHidden && $0.tintColor.cgColor.alpha > 0 })
}

/// VoiceOver reads concealed text as the blank it shows, while copy keeps its characters.
@MainActor
@Test func phoneVoiceOverReadsConcealedTextAsBlank() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    var terminal = Terminal(size: .init(columns: 12, rows: 3))
    _ = terminal.receive("pw \u{1B}[8ms🐦cret\u{1B}[28m!".utf8)
    view.display(terminal)

    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    let spoken = "pw \(String(repeating: " ", count: "s🐦cret".utf16.count))!"
    let line = try #require(transcript.accessibilityElements?.first as? UIAccessibilityElement)
    #expect(line.accessibilityLabel == spoken)
    transcript.selectAccessibleLine(0)
    #expect(view.selectedText == "pw s🐦cret!")
    let selected = try #require(transcript.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
        .first(where: { $0.accessibilityTraits.contains(.selected) }))
    #expect(selected.accessibilityValue == spoken)
}

/// Fresh bytes should preserve what a VoiceOver or touch reader scrolled back to.
@MainActor
@Test func phoneHistoryKeepsReaderAndOffersLatest() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    let scroll = try #require(transcript.subviews.compactMap { $0 as? UIScrollView }.first)
    let latest = try #require(transcript.subviews.compactMap { $0 as? UIButton }.first)
    var terminal = Terminal(size: .init(columns: 24, rows: 3))
    _ = terminal.receive((1...6).map { "Row \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    #expect(latest.isHidden)

    #expect(transcript.accessibilityScroll(.up))
    #expect(!latest.isHidden)
    let first = view.snapshot?.rows.first?.text
    let readingOffset = scroll.contentOffset
    _ = terminal.receive("\r\nRow 7".utf8)
    view.display(terminal)
    #expect(view.snapshot?.rows.first?.text == first)
    #expect(scroll.contentOffset == readingOffset)

    latest.sendActions(for: .touchUpInside)
    #expect(view.historyOffset == 0)
    #expect(latest.isHidden)
    #expect(view.snapshot?.rows.last?.text == "Row 7")

    _ = terminal.receive("\u{1b}[?1049h".utf8)
    view.display(terminal)
    #expect(!transcript.accessibilityScroll(.up))
    #expect(latest.isHidden)
}
#endif
