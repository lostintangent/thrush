import Testing
import ThrushCore
@testable import Thrush
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Test func cursorSpinnerFollowsTheGridWithoutMovingText() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let size = try #require(view.gridSize)
    let first = try #require(view.cellFrameInWindow(row: 0, column: 0))
    let originalBounds = view.bounds
    view.reducesMotion = true
    view.setWaiting("Connecting")
    let spinner = try #require(view.subviews.compactMap { $0 as? CursorSpinner }.first)
    let opening = try #require(view.cursorSpinnerFrameInWindow)
    #expect(first.contains(opening))
    #expect(abs(first.midX - opening.midX) < 0.01 && abs(first.midY - opening.midY) < 0.01)
    #if os(macOS)
    #expect(spinner.accessibilityRole() == .busyIndicator)
    #expect(spinner.accessibilityLabel() == "Connecting")
    #expect(!spinner.animates)
    #else
    #expect(spinner.isAccessibilityElement && spinner.accessibilityLabel == "Connecting")
    #expect(!spinner.isAnimating)
    #endif
    view.setWaiting("Reconnecting")
    view.setWaiting("Reconnecting")
    #expect(view.subviews.compactMap { $0 as? CursorSpinner }.first === spinner)
    #if os(macOS)
    #expect(spinner.accessibilityLabel() == "Reconnecting")
    #else
    #expect(spinner.accessibilityLabel == "Reconnecting")
    #endif
    var terminal = Terminal(size: size)
    _ = terminal.receive("keep this selection\u{1b}[\(size.rows);\(size.columns)H".utf8)
    view.display(terminal)
    view.selectWord(row: 0, column: 0)
    let last = try #require(view.cellFrameInWindow(row: size.rows - 1, column: size.columns - 1))
    let moved = try #require(view.cursorSpinnerFrameInWindow)
    #expect(last.contains(moved) && moved != opening)
    #expect(view.cursorCellFrameInWindow == last)
    view.reducesMotion = false
    #if os(macOS)
    #expect(spinner.animates)
    #else
    #expect(spinner.isAnimating)
    #endif
    _ = terminal.receive("\u{1b}[?25l".utf8)
    view.display(terminal)
    #expect(view.cursorSpinnerFrameInWindow == opening)
    view.setWaiting(nil)
    #expect(view.cursorSpinnerFrameInWindow == nil && spinner.superview == nil)
    #expect(view.gridSize == size && view.bounds == originalBounds)
    #expect(view.selectedText == "keep")
}

#if os(macOS)
@MainActor @Test func onlyAnUnmodifiedSingleGridClickReclaimsTheShell() async throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
    let window = try #require(mountTestView(view) as? NSWindow)
    defer { withExtendedLifetime(window) {} }
    let input = try #require(view.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let size = try #require(view.gridSize)
    var terminal = Terminal(size: size)
    _ = terminal.receive("one two\u{1b}[?1000h\u{1b}[?1006h".utf8)
    view.display(terminal)
    view.setInputAvailability(.holdingKeys, dismissKeyboard: false)
    var reclaims = 0
    var writes = 0
    view.onDisplacedTap = { reclaims += 1 }
    view.onInput = { _ in writes += 1 }

    func mouse(_ type: NSEvent.EventType, _ column: Int, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let cell = view.cellRect(row: 0, column: column)
        let point = input.convert(CGPoint(x: cell.midX, y: cell.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: clicks, pressure: 1))
    }
    input.mouseDown(with: try mouse(.leftMouseDown, 0))
    input.mouseDragged(with: try mouse(.leftMouseDragged, 2))
    input.mouseUp(with: try mouse(.leftMouseUp, 2))
    #expect(view.selectedText == "one")

    input.mouseDown(with: try mouse(.leftMouseDown, 6, flags: .shift))
    input.mouseUp(with: try mouse(.leftMouseUp, 6, flags: .shift))
    #expect(view.selectedText == "one two")

    input.mouseDown(with: try mouse(.leftMouseDown, 1))
    input.mouseUp(with: try mouse(.leftMouseUp, 1))
    input.mouseDown(with: try mouse(.leftMouseDown, 1, clicks: 2))
    input.mouseUp(with: try mouse(.leftMouseUp, 1, clicks: 2))
    try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.05))
    #expect(view.selectedText == "one" && reclaims == 0)
    #expect(input.accessibilityCustomActions()?.map(\.name).contains("Reconnect") == true)

    input.mouseDown(with: try mouse(.leftMouseDown, 5))
    #expect(reclaims == 0)
    input.mouseUp(with: try mouse(.leftMouseUp, 5))
    let deadline = ContinuousClock.now + .seconds(3)
    while reclaims == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(reclaims == 1 && writes == 0)
    #expect(!view.tapDisplacedGrid())
}
#endif
#if os(iOS)
@MainActor @Test func accessibilityCanReclaimFromTheSameTranscriptLineWithoutFocusingTheKeyboard() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: try #require(view.gridSize))
    _ = terminal.receive("still here".utf8)
    view.display(terminal)
    let transcript = try #require(view.subviews.compactMap { $0 as? PhoneTranscriptView }.first)
    func line() -> UIAccessibilityElement? {
        transcript.accessibilityElements?.compactMap { $0 as? UIAccessibilityElement }
            .first { $0.accessibilityLabel == "still here" }
    }
    let original = try #require(line())
    view.setInputAvailability(.holdingKeys, dismissKeyboard: false)
    var reclaims = 0
    var writes = 0
    view.onDisplacedTap = { reclaims += 1 }
    view.onInput = { _ in writes += 1 }
    #expect(line() === original)
    let action = try #require(original.accessibilityCustomActions?.first { $0.name == "Reconnect" })
    #expect(action.actionHandler?(action) == true)
    #expect(reclaims == 1 && writes == 0 && !view.phoneInput.isFirstResponder)
    #expect(line() === original && original.accessibilityCustomActions?.contains { $0.name == "Reconnect" } == false)
}
#endif
