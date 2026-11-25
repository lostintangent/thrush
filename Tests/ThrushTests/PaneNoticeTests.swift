import Testing
import ThrushCore
@testable import Thrush
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@Test func paneNoticesDistinguishRestorationFromFreshStart() {
    #expect(PaneNotice.connecting(retainingTranscript: false).isCentered)
    #expect(!PaneNotice.connecting(retainingTranscript: true).isCentered)
    #expect(PaneNotice.reconnecting.detail == "Typing waits for this shell to resume.")
    #expect(PaneNotice.replacement(discardedInput: false).detail == "New shell ready.")
    #expect(PaneNotice.replacement(discardedInput: true).detail == "New shell ready. Held input was discarded.")
    #expect(PaneNotice.displaced.action == "Use Here")
    #expect(PaneNotice.displaced.actionLabel == "Use shell in this window")
    #expect(PaneNotice.exited.action == "New Shell")
    #expect(PaneNotice.exited.actionLabel == "New Shell")
    #expect(PaneNotice.exited.actionHint == "Starts a new shell.")
}

@MainActor
@Test func paneStatusPreservesWholeGridAndBottomSelection() throws {
    let grid = TerminalView(frame: .zero)
    let pane = TerminalPaneContainer(terminal: grid)
    let frame = CGRect(x: 0, y: 0, width: 402, height: 550)
    #if os(macOS)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = pane
    #else
    let window = UIWindow(frame: frame)
    // Unhosted UIKit tests have no connected UIWindowScene. Mount a real native hierarchy so
    // renderer visibility and keyboard layout guides get the same window coordinate system.
    window.addSubview(pane)
    #endif
    pane.frame = frame
    defer { withExtendedLifetime(window) {} }

    func layout() {
        #if os(macOS)
        pane.layoutSubtreeIfNeeded()
        #else
        pane.setNeedsLayout()
        pane.layoutIfNeeded()
        #endif
    }
    var resizes: [Terminal.Size] = []
    grid.onGridSizeChange = { resizes.append($0) }
    layout()
    let size = try #require(grid.gridSize)
    #expect(size.rows > 5)
    #expect(size.columns > 12)
    let measured = grid.bounds.size
    let originalResizes = resizes
    var term = Terminal(size: size)
    _ = term.receive("\u{1b}[\(size.rows);1HLast line.".utf8)
    #expect(term.text(inRow: size.rows - 1) == "Last line.")
    grid.display(term)
    let range = TerminalView.Selection(anchorRow: size.rows - 1, anchorColumn: 0,
                                       headRow: size.rows - 1, headColumn: 8)
    grid.selection = range
    var activations = 0
    pane.onAction = { activations += 1 }
    let notices: [PaneNotice] = [.connecting(retainingTranscript: false), .reconnecting,
                                 .replacement(discardedInput: true), .displaced, .exited]
    for notice in notices {
        pane.show(notice)
        layout()
        #expect(grid.bounds.size == measured)
        #expect(grid.superview?.bounds.size == measured)
        #expect((pane.mountedNoticeView?.bounds.height ?? 0) > 0)
        #expect(grid.selection == range)
        #expect(grid.selectedText == "Last line")
        #expect(resizes == originalResizes)
        if let label = notice.actionLabel {
            #expect(grid.activatePaneAction(named: label))
            #expect(!grid.activatePaneAction(named: label))
        }
    }
    #expect(activations == 2)
    pane.show(nil)
    layout()
    #expect(grid.noticeBottomInset == 0)
    #expect(resizes == originalResizes)
}
