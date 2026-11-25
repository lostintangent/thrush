#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Thrush

@MainActor @Test(arguments: [false, true])
func macPaneFitsTheWindowContentLayout(fullSizeToolbar: Bool) throws {
    _ = NSApplication.shared
    let session = TerminalSession { _ in
        throw URLError(.cannotConnectToHost)
    }
    let terminal = TerminalView(frame: .zero)
    var pane = TerminalPane(session, isActive: false, theme: .slateDark)
    pane.preparedView = terminal
    var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
    if fullSizeToolbar { style.insert(.fullSizeContentView) }
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 720, height: 480),
                          styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if fullSizeToolbar {
        window.toolbar = NSToolbar(identifier: "Shell")
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: pane.ignoresSafeArea())
        host.sizingOptions = []
        window.contentView = host
    } else {
        let host = NSHostingView(rootView: pane)
        host.sizingOptions = []
        window.contentView = host
    }
    window.titlebarAppearsTransparent = true
    window.orderFront(nil)
    defer { window.close() }
    let host = try #require(window.contentView)
    host.layoutSubtreeIfNeeded()

    let container = try #require(terminal.superview as? TerminalPaneContainer)
    let paneFrame = container.convert(container.bounds, to: nil)
    let safe = window.contentLayoutRect
    if fullSizeToolbar {
        #expect(window.toolbar?.isVisible == true)
        #expect(paneFrame.maxY > safe.maxY)
    } else {
        #expect(paneFrame == safe)
    }
    #expect(paneFrame == host.convert(host.bounds, to: nil))
    let shade = TerminalTheme.slateDark.palette.background
    let fill = CGColor(srgbRed: CGFloat(shade.red) / 255, green: CGFloat(shade.green) / 255,
                       blue: CGFloat(shade.blue) / 255, alpha: 1)
    #expect(container.layer?.backgroundColor == fill)
    #expect(terminal.convert(terminal.bounds, to: nil) == safe)
    let input = try #require(terminal.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let firstCell = input.convert(terminal.cellRect(row: 0, column: 0), to: nil)
    #expect(!firstCell.isEmpty && safe.contains(firstCell))

}
#endif
