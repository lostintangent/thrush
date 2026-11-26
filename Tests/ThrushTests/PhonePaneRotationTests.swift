#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
import UIKit

/// UIKit supplies the geometry between the pane's safe top and its keyboard guide.
@MainActor private struct RotationPane {
    let portrait = CGSize(width: 402, height: 467)
    let landscape = CGSize(width: 750, height: 178)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 860, height: 640))
    let terminal = TerminalView(frame: .zero)
    let pane: TerminalPaneContainer

    init() {
        pane = TerminalPaneContainer(terminal: terminal)
        pane.frame = CGRect(origin: CGPoint(x: 35, y: 48), size: portrait)
        window.addSubview(pane)
        pane.layoutIfNeeded()
    }

    func resize(to size: CGSize) {
        pane.frame.size = size
        pane.setNeedsLayout()
        window.layoutIfNeeded()
        pane.layoutIfNeeded()
    }

    var usableRect: CGRect {
        var rect = pane.safeAreaLayoutGuide.layoutFrame
        rect.size.height = max(0, pane.keyboardLayoutGuide.layoutFrame.minY - rect.minY)
        return pane.convert(rect, to: window)
    }

    func cellInWindow(row: Int, column: Int = 0) -> CGRect {
        terminal.convert(terminal.cellRect(row: row, column: column), to: window)
    }
}

@MainActor @Test func rotatingLivePaneKeepsTheHeldCursorInsideTheKeyboardViewport() throws {
    let host = RotationPane()
    let terminal = host.terminal
    let portraitGrid = try #require(terminal.gridSize)
    var shell = Terminal(size: portraitGrid)
    let output = (1..<(portraitGrid.rows - 1)).map { "Compile unit \($0)" } + ["Build complete.", "~/thrush % "]
    _ = shell.receive(output.joined(separator: "\r\n").utf8)
    terminal.display(shell)
    let cursor = try #require(terminal.snapshot).cursorRow
    #expect(cursor == portraitGrid.rows - 1)
    let sourceCursor = terminal.cursorRect
    let sourceDrawable = terminal.drawableSize
    let portraitViewport = host.usableRect
    #expect(host.pane.viewportSize == portraitViewport.size)
    #expect(host.usableRect.contains(terminal.convert(sourceCursor, to: host.window)))
    #expect(sourceCursor.maxY > host.landscape.height)

    host.pane.beginRotation()
    host.resize(to: host.landscape)
    #expect(host.pane.viewportSize == host.usableRect.size)
    #expect(host.usableRect.height < portraitViewport.height)
    #expect(terminal.gridSize == portraitGrid)
    #expect(terminal.drawableSize == sourceDrawable)
    #expect(terminal.cursorRect == sourceCursor)
    #expect(terminal.historyOffset == 0)
    let heldCursor = terminal.convert(terminal.cursorRect, to: host.window)
    #expect(host.usableRect.contains(heldCursor))
    #expect(host.usableRect.contains(host.cellInWindow(row: cursor - 1)))

    host.pane.endRotation()
    host.pane.layoutIfNeeded()
    let settled = try #require(terminal.gridSize)
    #expect(settled.rows < portraitGrid.rows && settled.columns > portraitGrid.columns)
    #expect(terminal.bounds.size == host.pane.viewportSize)
    host.resize(to: host.portrait)
    #expect(terminal.gridSize == portraitGrid)
}

/// History archived on replacement stays above the live screen even as the pane grows.
@MainActor @Test func growingReplacementShellKeepsItsPromptBelowItsOwnHistory() throws {
    let host = RotationPane()
    let terminal = host.terminal
    host.resize(to: host.landscape)
    let size = try #require(terminal.gridSize)
    var shell = Terminal(size: size)
    _ = shell.receive(String(repeating: "archived\r\n", count: 60).utf8)
    shell.startNewShell(at: size)
    let rows = Array(repeating: "fresh", count: size.rows + 2) + ["new$ "]
    _ = shell.receive(rows.joined(separator: "\r\n").utf8)
    terminal.replaceDisplayedSnapshot(shell.snapshot(), receivedAt: nil, archivingMainScreen: true)
    #expect(shell.snapshot().currentShellHistoryCount == 3)
    #expect(terminal.historyCount > shell.snapshot().currentShellHistoryCount)

    host.pane.beginRotation()
    host.resize(to: host.portrait)
    let held = terminal.convert(terminal.cursorRect, to: host.window)
    #expect(terminal.publishHeldGrid(for: host.pane.viewportSize))
    let destination = try #require(terminal.gridSize)
    terminal.onHeldGridReady = { host.pane.endRotation() }
    shell.resize(to: destination)
    terminal.replaceDisplayedSnapshot(shell.snapshot(), receivedAt: nil)
    #expect(!terminal.holdsGridGeometry)
    #expect(terminal.convert(terminal.cursorRect, to: host.window) == held)
    let displayed = try #require(terminal.snapshot)
    #expect(displayed.rows[displayed.cursorRow].text == "new$ ")
    #expect(displayed.history.contains { $0.text == "archived" })
}

/// A taller grid pulls history back above a cursor on the bottom row, so the held source
/// frame waits where the resized frame will draw the prompt.
@MainActor @Test func growingTurnHoldsThePromptWhereTheTallerGridPullsIt() throws {
    // A little history all comes back, and plenty of it fills the taller grid.
    for lines in [19, 60] {
        let host = RotationPane()
        let terminal = host.terminal
        host.resize(to: host.landscape)
        let landscapeGrid = try #require(terminal.gridSize)
        var shell = Terminal(size: landscapeGrid)
        _ = shell.receive(((1..<lines).map { "Line \($0)" } + ["~/thrush % "]).joined(separator: "\r\n").utf8)
        terminal.display(shell)
        #expect(terminal.snapshot?.cursorRow == landscapeGrid.rows - 1)

        host.pane.beginRotation()
        host.resize(to: host.portrait)
        let held = terminal.convert(terminal.cursorRect, to: host.window)
        #expect(host.usableRect.contains(held))

        host.pane.endRotation()
        host.pane.layoutIfNeeded()
        shell.resize(to: try #require(terminal.gridSize))
        terminal.display(shell)
        let settled = terminal.convert(terminal.cursorRect, to: host.window)
        #expect(terminal.snapshot?.rows[terminal.snapshot!.cursorRow].text.hasPrefix("~/thrush %") == true)
        #expect(settled == held, "\(lines) lines held the prompt at \(held.minY), settled at \(settled.minY)")
    }
}

@MainActor @Test func rotatingScrolledPaneKeepsTheFirstVisibleHistoryRowsInPlace() throws {
    let host = RotationPane()
    let terminal = host.terminal
    let portraitGrid = try #require(terminal.gridSize)
    var shell = Terminal(size: portraitGrid)
    _ = shell.receive((1...(portraitGrid.rows + 8)).map { "Log entry \($0)" }.joined(separator: "\r\n").utf8)
    terminal.display(shell)
    terminal.setHistoryOffset(5)
    let visibleRows = try #require(terminal.snapshot).rows.prefix(3).map(\.text)
    #expect(visibleRows == ["Log entry 4", "Log entry 5", "Log entry 6"])
    let firstCell = host.cellInWindow(row: 0)
    #expect(!firstCell.isEmpty)

    host.pane.beginRotation()
    host.resize(to: host.landscape)
    #expect(host.pane.viewportSize == host.usableRect.size)
    #expect(terminal.gridSize == portraitGrid)
    #expect(terminal.historyOffset == 5)
    #expect(terminal.snapshot?.rows.prefix(3).map(\.text) == visibleRows)
    #expect(host.cellInWindow(row: 0) == firstCell)
    #expect(host.usableRect.contains(firstCell))
    #expect(host.usableRect.contains(host.cellInWindow(row: 2)))

    host.pane.endRotation()
    host.pane.layoutIfNeeded()
    #expect(terminal.bounds.size == host.usableRect.size)
}

/// Drawing the source grid in the destination bounds would show its top rows for a frame.
/// The pane keeps the held frame until the terminal delivers the destination grid.
@MainActor @Test func heldPaneMovesToTheDestinationWithItsFirstResizedFrame() throws {
    let host = RotationPane()
    let terminal = host.terminal
    let portraitGrid = try #require(terminal.gridSize)
    var shell = Terminal(size: portraitGrid)
    let output = (1..<(portraitGrid.rows - 1)).map { "Compile unit \($0)" } + ["Build complete.", "~/thrush % "]
    _ = shell.receive(output.joined(separator: "\r\n").utf8)
    terminal.display(shell)
    var emitted: [Terminal.Size] = []
    terminal.onGridSizeChange = { emitted.append($0) }
    var ready = 0
    terminal.onHeldGridReady = {
        ready += 1
        host.pane.endRotation()
    }

    host.pane.beginRotation()
    host.resize(to: host.landscape)
    let heldBounds = terminal.bounds
    let heldCursor = terminal.convert(terminal.cursorRect, to: host.window)
    #expect(terminal.publishHeldGrid(for: host.pane.viewportSize))
    let settled = try #require(emitted.first)
    #expect(emitted == [settled] && terminal.gridSize == settled)
    #expect(settled.rows < portraitGrid.rows && settled.columns > portraitGrid.columns)
    host.pane.layoutIfNeeded()
    #expect(terminal.holdsGridGeometry && terminal.bounds == heldBounds)
    #expect(terminal.convert(terminal.cursorRect, to: host.window) == heldCursor)

    _ = shell.receive("l".utf8)
    terminal.display(shell)
    #expect(ready == 0 && terminal.holdsGridGeometry && terminal.bounds == heldBounds)

    shell.resize(to: settled)
    terminal.display(shell)
    #expect(ready == 1 && !terminal.holdsGridGeometry)
    #expect(terminal.bounds.size == host.pane.viewportSize)
    #expect(emitted == [settled])
    let cursor = terminal.convert(terminal.cursorRect, to: host.window)
    #expect(host.usableRect.contains(cursor))
    #expect(abs(cursor.maxY - heldCursor.maxY) < cursor.height)
}

/// The turn grows the viewport toward a stale guide while the keyboard animates its height, then
/// the destination guide shortens it without an animation. The viewport must keep presenting the
/// held prompt.
@MainActor @Test func viewportKeepsPresentingWhenTheGuideSettlesMidTurn() async throws {
    let host = RotationPane()
    host.window.isHidden = false
    host.resize(to: host.landscape)
    let viewport = try #require(host.terminal.superview)
    func presentedHeight() -> CGFloat { viewport.layer.presentation()?.bounds.height ?? viewport.bounds.height }

    let start = viewport.bounds.height
    host.pane.beginRotation()
    // UIKit lists a later transaction's animations first, so the keyboard's comes after the turn.
    for (key, from, to) in [("bounds.size", NSValue(cgSize: CGSize(width: 0, height: -20)), NSValue(cgSize: .zero)),
                            ("position", NSValue(cgPoint: CGPoint(x: 0, y: -10)), NSValue(cgPoint: .zero))] {
        let keyboard = CABasicAnimation(keyPath: key)
        keyboard.isAdditive = true
        keyboard.fromValue = from
        keyboard.toValue = to
        keyboard.duration = 1
        viewport.layer.add(keyboard, forKey: "keyboard " + key)
    }
    try await Task.sleep(for: .milliseconds(20))
    UIView.animate(withDuration: 1) { host.resize(to: CGSize(width: 402, height: 768)) }
    try await Task.sleep(for: .milliseconds(200))
    let before = presentedHeight()
    #expect(before > start + 1)
    host.resize(to: host.portrait)

    var lowest = presentedHeight()
    var topDrift: CGFloat = 0
    let deadline = ContinuousClock.now + .seconds(3)
    while viewport.layer.animationKeys() != nil && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(8))
        lowest = min(lowest, presentedHeight())
        topDrift = max(topDrift, abs((viewport.layer.presentation()?.frame.minY ?? 0) - viewport.frame.minY))
    }
    #expect(lowest >= before - 1, "presented \(lowest) after \(before)")
    #expect(topDrift <= 1)
    host.pane.endRotation()
}

@MainActor @Test func heldPaneReleasesWhenTheConnectionSendsNoResizedFrame() async throws {
    let host = RotationPane()
    let controller = PhonePaneController(host.pane)
    controller.loadViewIfNeeded()
    let terminal = host.terminal
    terminal.display(Terminal(size: try #require(terminal.gridSize)))
    host.pane.beginRotation()
    host.resize(to: host.landscape)
    controller.finishRotation()
    #expect(terminal.holdsGridGeometry)
    try await Task.sleep(for: PhonePaneController.frameWait * 2)
    #expect(!terminal.holdsGridGeometry)
    #expect(terminal.bounds.size == host.pane.viewportSize)
}

/// The keyboard can resize the source-orientation pane before its controller receives
/// viewWillTransition. Replay the observed usable sizes at the native resize boundary.
@MainActor @Test func sourceKeyboardResizeCanBeHeldBeforeItPublishesAnIntermediateGrid() throws {
    let host = RotationPane()
    host.window.frame.size = CGSize(width: 950, height: 950)
    host.pane.frame.origin = CGPoint(x: 80, y: 100)
    host.resize(to: host.portrait)
    let view = host.terminal
    #expect(host.pane.viewportSize == host.portrait)
    var emitted: [Terminal.Size] = []
    view.onGridSizeChange = { emitted.append($0) }

    func turn(early: CGSize, destination: CGSize, settled: Terminal.Size) throws {
        let source = view.bounds.size
        let grid = try #require(view.gridSize)
        let drawable = view.drawableSize
        var intercepted = false
        // The hosted peer verifies UIKit's keyboard notification and guide. Here
        // the recorded early viewport is delivered deterministically by Auto Layout.
        view.beforeViewportResize = { previous in
            guard view.bounds.size == early && !intercepted else { return }
            intercepted = true
            #expect(previous == source)
            #expect(view.gridSize == grid)
            host.pane.beginRotation(sourceHeight: previous.height)
        }
        host.resize(to: early)
        #expect(intercepted)
        #expect(host.pane.viewportSize == early)
        #expect(view.gridSize == grid && view.drawableSize == drawable)
        #expect(emitted.isEmpty)
        // This is the later start signal used by the rotation coordinator.
        host.pane.beginRotation()
        host.resize(to: destination)
        #expect(host.pane.viewportSize == destination)
        #expect(view.bounds.height == source.height)
        #expect(view.gridSize == grid && view.drawableSize == drawable)
        #expect(emitted.isEmpty)

        host.pane.endRotation()
        host.pane.layoutIfNeeded()
        #expect(view.gridSize == settled)
        #expect(emitted == [settled])
        emitted.removeAll()
        view.beforeViewportResize = nil
    }

    try turn(early: CGSize(width: 402, height: 588), destination: host.landscape,
             settled: .init(columns: 90, rows: 9))
    try turn(early: CGSize(width: 750, height: 358), destination: host.portrait,
             settled: .init(columns: 47, rows: 25))
}
#endif
