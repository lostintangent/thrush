#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Thrush

enum MacPaneHost: CaseIterable {
    case window, toolbar, toolbarIgnoringSafeArea, paddedToolbar
}

@MainActor @Test(arguments: MacPaneHost.allCases)
func macPaneFitsTheWindowContentLayout(host layout: MacPaneHost) throws {
    _ = NSApplication.shared
    let session = TerminalSession { _ in
        throw URLError(.cannotConnectToHost)
    }
    let terminal = TerminalView(frame: .zero)
    var pane = TerminalPane(session, isActive: false, theme: .slateDark)
    pane.preparedView = terminal
    var style: NSWindow.StyleMask = [.titled, .closable, .resizable]
    if layout != .window { style.insert(.fullSizeContentView) }
    let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 720, height: 480),
                          styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    if layout != .window {
        window.toolbar = NSToolbar(identifier: "Shell")
        window.toolbarStyle = .unified
    }
    let root = switch layout {
    case .window, .toolbar: AnyView(pane)
    case .toolbarIgnoringSafeArea: AnyView(pane.ignoresSafeArea())
    case .paddedToolbar: AnyView(pane.padding(24))
    }
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = []
    window.contentView = hosting
    window.titlebarAppearsTransparent = true
    window.orderFront(nil)
    defer { window.close() }
    let host = try #require(window.contentView)
    host.layoutSubtreeIfNeeded()

    let container = try #require(terminal.superview as? TerminalPaneContainer)
    let paneFrame = container.convert(container.bounds, to: nil)
    let bounds = host.convert(host.bounds, to: nil)
    // A pane meeting the toolbar's edge paints beneath it. A padded pane stays inside the safe area.
    let safe = layout == .paddedToolbar ? window.contentLayoutRect.insetBy(dx: 24, dy: 24) : window.contentLayoutRect
    switch layout {
    case .window:
        #expect(paneFrame == safe && paneFrame == bounds)
    case .toolbar, .toolbarIgnoringSafeArea:
        #expect(window.toolbar?.isVisible == true)
        #expect(paneFrame.maxY > safe.maxY && paneFrame == bounds)
    case .paddedToolbar:
        #expect(paneFrame == safe)
    }
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
