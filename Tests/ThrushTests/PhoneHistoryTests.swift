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
    #expect(!history.accessibilityScroll(.up))
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

/// A program that takes scrolling gets a one-finger swipe as rows, and a flick coasts until it
/// slows below a row or a touch stops it without clicking.
@MainActor
@Test func swipesScrollFullScreenProgramsAndFlicksCoast() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    view.layoutIfNeeded()
    let history = try #require(view.subviews.compactMap { $0 as? PhoneHistoryScrollView }.first)
    let scroll = try #require(history.subviews.compactMap { $0 as? UIScrollView }.first)
    let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
    let recognizers = scroll.gestureRecognizers ?? []
    let swipe = try #require(recognizers.first { $0 is UIPanGestureRecognizer && $0 !== scroll.panGestureRecognizer
        && $0.allowedTouchTypes.contains(direct) })
    let tap = try #require(recognizers.first { $0 is UITapGestureRecognizer && $0.allowedTouchTypes.contains(direct) })
    var terminal = Terminal(size: .init(columns: 24, rows: 6))
    _ = terminal.receive((1...12).map { "Row \($0)" }.joined(separator: "\r\n").utf8)
    view.display(terminal)
    var sent: [String] = []
    view.onInput = { sent.append(String(decoding: terminal.encode($0), as: UTF8.self)) }
    let row = view.cellRect(row: 0, column: 0).height
    let cell = view.cellRect(row: 2, column: 4)
    let point = CGPoint(x: cell.midX, y: cell.midY)

    // The shell's history keeps the swipe.
    #expect(!history.gestureRecognizer(swipe, shouldReceive: UITouch()))
    history.swipe(.began, by: 12, at: point, velocity: 0)
    history.swipe(.changed, by: row * 3, at: point, velocity: 0)
    #expect(sent.isEmpty)

    // Moving the finger down reaches earlier lines, as in a list. The pan's starting slop moves nothing.
    _ = terminal.receive("\u{1b}[?1049h".utf8)
    view.display(terminal)
    #expect(history.gestureRecognizer(swipe, shouldReceive: UITouch()))
    history.swipe(.began, by: 12, at: point, velocity: 0)
    history.swipe(.changed, by: row * 2.5, at: point, velocity: 0)
    history.swipe(.changed, by: -row * 4, at: point, velocity: 0)
    #expect(sent == ["\u{1b}[A", "\u{1b}[A", "\u{1b}[B", "\u{1b}[B", "\u{1b}[B"])

    // UIScrollView's normal deceleration carries a 1,000 point per second flick about 499 points.
    sent = []
    _ = terminal.receive("\u{1b}[?1000;1006h".utf8)
    view.display(terminal)
    history.swipe(.began, by: 0, at: point, velocity: 0)
    history.swipe(.ended, by: -row, at: point, velocity: -1000, releasedAt: 10)
    #expect(sent == ["\u{1b}[<65;5;3M"])
    history.coast(to: 10.1)
    let early = sent.count
    history.coast(to: 20)
    #expect(early > 1 && early < sent.count)
    #expect(abs(sent.count - 1 - Int(499 / row)) <= 1)
    #expect(Set(sent) == ["\u{1b}[<65;5;3M"])
    #expect(!history.isCoasting)

    // A touch catches a flick, and that touch doesn't click.
    sent = []
    history.swipe(.began, by: 0, at: point, velocity: 0)
    history.swipe(.ended, by: 0, at: point, velocity: 2000, releasedAt: 30)
    history.coast(to: 30.05)
    let caught = sent.count
    #expect(caught > 0 && Set(sent) == ["\u{1b}[<64;5;3M"])
    #expect(!history.gestureRecognizer(tap, shouldReceive: UITouch()))
    history.coast(to: 31)
    #expect(sent.count == caught && !history.isCoasting)
    #expect(history.gestureRecognizer(tap, shouldReceive: UITouch()))
}
#endif
