#if os(iOS)
import Testing
import Thrush
@testable import ThrushUI
import UIKit

@MainActor
@Test func phoneKeepsDrawablePixelsAtNativeSizeAcrossKeyboardOpenRotation() throws {
    let portrait = CGSize(width: 402, height: 467)
    let landscape = CGSize(width: 750, height: 178)
    let view = TerminalView(frame: CGRect(origin: .zero, size: portrait))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let cell = view.cellRect(row: 0, column: 0)
    for size in [landscape, portrait] {
        view.bounds.size = size
        view.layoutIfNeeded()
        #expect(view.contentMode == .topLeft)
        #expect(view.layer.contentsGravity != .resize)
        #expect(view.cellRect(row: 0, column: 0) == cell)
        let scale = view.traitCollection.displayScale
        #expect(view.drawableSize == CGSize(width: size.width * scale, height: size.height * scale))
    }
}

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
    // UIKit adjusts contentOffset during layout even when nobody scrolled.
    scroll.setContentOffset(.zero, animated: false)
    #expect(view.historyOffset == 0)
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

/// The selection can cross both lower corners while someone reads history with the keyboard open.
@MainActor
@Test func latestAndBothSelectionHandlesKeepSeparateTouchTargets() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 467))
    let window = UIWindow(frame: view.frame)
    window.addSubview(view)
    window.isHidden = false
    defer { window.isHidden = true }
    view.layoutIfNeeded()
    let size = try #require(view.gridSize)
    var terminal = Terminal(size: size)
    _ = terminal.receive((1...(size.rows + 8)).map { "Compile unit \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    view.setHistoryOffset(2)
    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    let latest = try #require(transcript.subviews.compactMap { $0 as? UIButton }.first)
    transcript.layoutIfNeeded()
    let trailing = latest.convert(latest.bounds, to: transcript)
    let leading = CGRect(x: 12, y: trailing.minY, width: trailing.width, height: trailing.height)
    let cell = try #require(view.cell(at: CGPoint(x: trailing.midX, y: trailing.midY)))
    transcript.selectAccessibleLine(cell.row)
    let targets = transcript.subviews.filter { $0.subviews.contains { $0 is any UITextSelectionHandleView } }
    #expect(targets.count == 2)
    func hit(_ point: CGPoint) -> UIView? { window.hitTest(transcript.convert(point, to: window), with: nil) }
    // The captured compile path ends after 37 cells on its second row. Also check
    // a selection ending directly at the button's original center.
    for (row, column) in [(cell.row + 1, 36), (cell.row, cell.column - 1)] {
        view.selection = .init(anchorRow: cell.row, anchorColumn: 0, headRow: row, headColumn: column)
        for corner in [trailing, leading] {
            #expect(targets.contains { !$0.isHidden && $0.frame.intersects(corner) })
        }
        let frame = latest.convert(latest.bounds, to: transcript)
        #expect(transcript.bounds.contains(frame))
        #expect(targets.allSatisfy { !$0.frame.intersects(frame) && hit($0.center) === $0 })
        let control = hit(CGPoint(x: frame.midX, y: frame.midY))
        #expect(control === latest || control?.isDescendant(of: latest) == true)
    }
    latest.sendActions(for: .touchUpInside)
    #expect(view.historyOffset == 0 && latest.isHidden)
}
#endif
