#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
import UIKit

@MainActor
@Test func phoneKeepsDrawablePixelsAtNativeSizeAcrossKeyboardOpenRotation() throws {
    let portrait = CGSize(width: 402, height: 467)
    let landscape = CGSize(width: 750, height: 178)
    let view = TerminalMetalView(frame: CGRect(origin: .zero, size: portrait))
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
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    var terminal = Terminal(size: .init(columns: 8, rows: 5))
    _ = terminal.receive("Build comp".utf8)
    _ = terminal.receive("lete.\r\nA翼🐦Z".utf8)
    view.display(terminal)

    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let lines = try #require(history.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement })
    #expect(lines.map(\.accessibilityLabel) == ["Build complete.", "A翼🐦Z"])
    #expect(lines[0].accessibilityFrameInContainerSpace.height == view.cellRect(row: 0, column: 0).height * 2)
    history.selectAccessibleLine(1)
    #expect(view.selectedText == "Build complete.")
    let selected = try #require(history.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
        .first(where: { $0.accessibilityTraits.contains(.selected) }))
    #expect(selected.accessibilityValue == view.selectedText)
    #expect(selected.accessibilityCustomActions?.map(\.name) == ["Copy", "Clear selection"])

    let handles = history.subviews.flatMap(\.subviews).filter { $0 is any UITextSelectionHandleView }
    #expect(handles.count == 2)
    #expect(handles.allSatisfy { !$0.frame.isEmpty && !$0.isHidden && $0.tintColor.cgColor.alpha > 0 })
}

/// VoiceOver reads concealed text as the blank it shows, while copy keeps its characters.
@MainActor
@Test func phoneVoiceOverReadsConcealedTextAsBlank() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    var terminal = Terminal(size: .init(columns: 12, rows: 3))
    _ = terminal.receive("pw \u{1B}[8ms🐦cret\u{1B}[28m!".utf8)
    view.display(terminal)

    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let spoken = "pw \(String(repeating: " ", count: "s🐦cret".utf16.count))!"
    let line = try #require(history.accessibilityElements?.first as? UIAccessibilityElement)
    #expect(line.accessibilityLabel == spoken)
    history.selectAccessibleLine(0)
    #expect(view.selectedText == "pw s🐦cret!")
    let selected = try #require(history.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
        .first(where: { $0.accessibilityTraits.contains(.selected) }))
    #expect(selected.accessibilityValue == spoken)
}

/// Fresh bytes should preserve what a VoiceOver or touch reader scrolled back to.
@MainActor
@Test func phoneHistoryKeepsReaderAndOffersLatest() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let scroll = try #require(history.subviews.compactMap { $0 as? UIScrollView }.first)
    let latest = try #require(history.subviews.compactMap { $0 as? UIButton }.first)
    var terminal = Terminal(size: .init(columns: 24, rows: 3))
    _ = terminal.receive((1...6).map { "Row \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    #expect(latest.isHidden)
    // UIKit adjusts contentOffset during layout even when nobody scrolled.
    scroll.setContentOffset(.zero, animated: false)
    #expect(view.historyOffset == 0)
    #expect(latest.isHidden)

    #expect(history.accessibilityScroll(.up))
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
    // The page goes to the full-screen program, so history stays where it is.
    #expect(history.accessibilityScroll(.up))
    #expect(view.historyOffset == 0)
    #expect(latest.isHidden)
}

/// The selection can cross both lower corners while someone reads history with the keyboard open.
@MainActor
@Test func latestAndBothSelectionHandlesKeepSeparateTouchTargets() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 402, height: 467))
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
    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let latest = try #require(history.subviews.compactMap { $0 as? UIButton }.first)
    history.layoutIfNeeded()
    let trailing = latest.convert(latest.bounds, to: history)
    let leading = CGRect(x: 12, y: trailing.minY, width: trailing.width, height: trailing.height)
    let cell = try #require(view.cell(at: CGPoint(x: trailing.midX, y: trailing.midY)))
    history.selectAccessibleLine(cell.row)
    let targets = history.subviews.filter { $0.subviews.contains { $0 is any UITextSelectionHandleView } }
    #expect(targets.count == 2)
    func hit(_ point: CGPoint) -> UIView? { window.hitTest(history.convert(point, to: window), with: nil) }
    // The captured compile path ends after 37 cells on its second row. Also check
    // a selection ending directly at the button's original center.
    for (row, column) in [(cell.row + 1, 36), (cell.row, cell.column - 1)] {
        view.selection = .init(anchorRow: cell.row, anchorColumn: 0, headRow: row, headColumn: column)
        for corner in [trailing, leading] {
            #expect(targets.contains { !$0.isHidden && $0.frame.intersects(corner) })
        }
        let frame = latest.convert(latest.bounds, to: history)
        #expect(history.bounds.contains(frame))
        #expect(targets.allSatisfy { !$0.frame.intersects(frame) && hit($0.center) === $0 })
        let control = hit(CGPoint(x: frame.midX, y: frame.midY))
        #expect(control === latest || control?.isDescendant(of: latest) == true)
    }
    latest.sendActions(for: .touchUpInside)
    #expect(view.historyOffset == 0 && latest.isHidden)
}

@MainActor
@Test func growingPhoneHistoryKeepsItsLiveOrScrolledPosition() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 402, height: 467))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let size = Terminal.Size(columns: 47, rows: 25)
    var terminal = Terminal(size: size)
    _ = terminal.receive((1...8).map { "Old row \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    terminal.startNewShell(at: size)
    _ = terminal.receive("new prompt\r\nfinal output\r\n".utf8)
    view.replaceDisplayedSnapshot(terminal.snapshot(), receivedAt: nil, archivingMainScreen: true)

    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let scroll = try #require(history.subviews.compactMap { $0 as? UIScrollView }.first)
    let rowHeight = view.cellRect(row: 0, column: 0).height
    func resize(_ height: CGFloat, readingFromBottom offset: Int) {
        view.frame.size.height = height
        view.layoutIfNeeded()
        #expect(scroll.bounds.height == height)
        #expect(scroll.contentSize.height == height + CGFloat(view.historyCount) * rowHeight)
        #expect(scroll.contentOffset.y == CGFloat(view.historyCount - offset) * rowHeight)
        #expect(view.historyOffset == offset)
    }
    resize(800, readingFromBottom: 0)
    #expect(view.snapshot?.cursorRow == terminal.snapshot().cursorRow)
    #expect(view.snapshot?.rows.first?.text == "new prompt")

    resize(467, readingFromBottom: 0)
    view.setHistoryOffset(3)
    let first = view.snapshot?.rows.first?.text
    resize(800, readingFromBottom: 3)
    #expect(view.snapshot?.rows.first?.text == first)
}

/// A program that takes scrolling gets the scroll view's own pan and glide through an endless extent, so only a
/// person's swipe reaches it, and history comes back where the reader left it.
@MainActor
@Test func fullScreenProgramsTakeTheScrollViewsOwnPanAndGlide() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let scroll = try #require(history.subviews.compactMap { $0 as? UIScrollView }.first)
    var terminal = Terminal(size: .init(columns: 24, rows: 6))
    _ = terminal.receive((1...12).map { "Row \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    var sent: [String] = []
    view.onInput = { sent.append(String(decoding: terminal.encode($0), as: UTF8.self)) }
    let row = view.cellRect(row: 0, column: 0).height
    let reading = (scroll.contentSize, scroll.contentOffset)
    #expect(reading.1.y == CGFloat(view.historyCount) * row && scroll.showsVerticalScrollIndicator)

    _ = terminal.receive("\u{1b}[?1049h".utf8)
    view.display(terminal)
    let rest = scroll.contentOffset.y
    #expect(rest >= 100_000 && scroll.contentSize.height - scroll.bounds.height - rest >= 100_000)
    #expect(!scroll.showsVerticalScrollIndicator)
    // UIKit's own moves, as when the keyboard resizes the viewport, leave the program alone, and a resting
    // scroll view returns to the middle.
    scroll.contentOffset.y -= row * 3
    #expect(sent.isEmpty)
    history.synchronize()
    #expect(scroll.contentOffset.y == rest)

    _ = terminal.receive("\u{1b}[?1049l".utf8)
    view.display(terminal)
    #expect(scroll.contentSize == reading.0 && scroll.contentOffset == reading.1)
    #expect(scroll.showsVerticalScrollIndicator)
}

/// VoiceOver's three-finger scroll pages a full-screen program and reads the page once the program redraws it.
@MainActor
@Test func voiceOverPagesFullScreenProgramsAndReadsTheirRedraw() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    var terminal = Terminal(size: .init(columns: 24, rows: 6))
    _ = terminal.receive("\u{1b}[?1049h\u{1b}[2;1Hpage one".utf8)
    view.display(terminal)
    var sent: [String] = []
    var read: [String] = []
    view.onInput = { sent.append(String(decoding: terminal.encode($0), as: UTF8.self)) }
    view.onAccessibilityAnnouncement = { read.append($0) }

    #expect(history.accessibilityScroll(.down))
    #expect(sent == Array(repeating: "\u{1b}[B", count: 5))
    #expect(read.isEmpty)
    _ = terminal.receive("\u{1b}[H\u{1b}[2Jpage two".utf8)
    view.display(terminal)
    #expect(read == ["page two"])

    sent = []
    _ = terminal.receive("\u{1b}[?1000;1006h".utf8)
    view.display(terminal)
    #expect(history.accessibilityScroll(.up))
    #expect(sent == Array(repeating: "\u{1b}[<64;13;4M", count: 5))
    #expect(read == ["page two"] && view.historyOffset == 0)
}
#endif
