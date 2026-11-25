#if os(macOS)
import AppKit
import Testing
import Thrush
@testable import ThrushUI

@MainActor @Test func macPaneNoticesPreserveTheTranscriptResponderAndExposeNativeActions() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let terminal = TerminalView(frame: window.contentLayoutRect)
    let pane = TerminalPaneContainer(terminal: terminal)
    window.contentView = pane
    pane.layoutSubtreeIfNeeded()
    let input = try #require(terminal.subviews.compactMap { $0 as? MacTerminalInput }.first)
    var shell = Terminal(size: try #require(terminal.gridSize))
    _ = shell.receive("Final transcript line.".utf8)
    terminal.display(shell)
    terminal.selection = .init(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 4)
    #expect(terminal.focusInput())
    let value = try #require(input.accessibilityValue() as? String)
    var activations = 0
    pane.onAction = { activations += 1 }

    func action(in root: NSView) -> NSButton? {
        if let button = root as? NSButton, button.accessibilityIdentifier() == "terminal.status.action" { return button }
        return root.subviews.lazy.compactMap(action).first
    }
    for notice in [PaneNotice.reconnecting, .displaced, .exited] {
        pane.show(notice)
        pane.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === input)
        #expect(input.accessibilityValue() as? String == value)
        #expect(input.accessibilitySelectedText() == "Final")
        let surface = try #require(pane.mountedNoticeView)
        if let label = notice.actionLabel, let caption = notice.action {
            let button = try #require(action(in: surface))
            let descendant = try #require(NSAccessibility.unignoredDescendant(of: button) as? NSAccessibilityProtocol)
            #expect(button.title == caption)
            #expect(descendant.accessibilityRole() == .button)
            #expect(descendant.accessibilityTitle() == label)
            #expect(descendant.accessibilityLabel() == label)
            #expect(descendant.accessibilityUserInputLabels() == [caption])
            #expect(descendant.accessibilityHelp() == notice.actionHint)
            #expect(button.isEnabled)
            let before = activations
            _ = descendant.accessibilityPerformPress()
            #expect(activations == before + 1)
        }
        pane.show(notice)
        #expect(pane.mountedNoticeView === surface)
    }
    #expect(activations == 2)
}
#endif
