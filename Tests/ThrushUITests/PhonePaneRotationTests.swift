#if os(iOS)
import Testing
import Thrush
@testable import ThrushUI
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
#endif
