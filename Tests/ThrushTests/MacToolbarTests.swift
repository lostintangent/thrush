#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Thrush

enum MacWindowLayout: CaseIterable {
    case window, toolbar, toolbarIgnoringSafeArea, paddedToolbar
}

@MainActor @Test(arguments: MacWindowLayout.allCases)
func macViewFitsTheWindowContentLayout(host layout: MacWindowLayout) throws {
    _ = NSApplication.shared
    let session = TerminalSession { _ in
        throw URLError(.cannotConnectToHost)
    }
    let terminal = TerminalMetalView(frame: .zero)
    var terminalView = TerminalView(session, isActive: false, theme: .slateDark)
    terminalView.probe.metalView = terminal
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
    case .window, .toolbar: AnyView(terminalView)
    case .toolbarIgnoringSafeArea: AnyView(terminalView.ignoresSafeArea())
    case .paddedToolbar: AnyView(terminalView.padding(24))
    }
    let hosting = NSHostingView(rootView: root)
    hosting.sizingOptions = []
    window.contentView = hosting
    window.titlebarAppearsTransparent = true
    window.orderFront(nil)
    defer { window.close() }
    let host = try #require(window.contentView)
    host.layoutSubtreeIfNeeded()

    let canvas = try #require(terminal.superview as? CanvasView)
    let canvasFrame = canvas.convert(canvas.bounds, to: nil)
    let bounds = host.convert(host.bounds, to: nil)
    // A view meeting the toolbar's edge paints beneath it. A padded view stays inside the safe area.
    let safe = layout == .paddedToolbar ? window.contentLayoutRect.insetBy(dx: 24, dy: 24) : window.contentLayoutRect
    switch layout {
    case .window:
        #expect(canvasFrame == safe && canvasFrame == bounds)
    case .toolbar, .toolbarIgnoringSafeArea:
        #expect(window.toolbar?.isVisible == true)
        #expect(canvasFrame.maxY > safe.maxY && canvasFrame == bounds)
    case .paddedToolbar:
        #expect(canvasFrame == safe)
    }
    let shade = TerminalTheme.slateDark.palette.background
    let fill = CGColor(srgbRed: CGFloat(shade.red) / 255, green: CGFloat(shade.green) / 255,
                       blue: CGFloat(shade.blue) / 255, alpha: 1)
    #expect(canvas.layer?.backgroundColor == fill)
    #expect(terminal.convert(terminal.bounds, to: nil) == safe)
    let input = try #require(terminal.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let firstCell = input.convert(terminal.cellRect(row: 0, column: 0), to: nil)
    #expect(!firstCell.isEmpty && safe.contains(firstCell))

}
#endif
