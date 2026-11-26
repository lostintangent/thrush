import SwiftUI
import Testing
@testable import Thrush

#if os(macOS)
/// An offscreen test window still represents the selected, visible tab.
@MainActor private final class SelectedTabWindow: NSWindow {
    override var occlusionState: OcclusionState { .visible }
}
#endif

@MainActor @Observable private final class SelectedSession {
    var session: TerminalSession
    init(_ session: TerminalSession) { self.session = session }
}

@MainActor private struct SessionTab: View {
    let selected: SelectedSession
    var body: some View { TerminalView(selected.session) }
}

@MainActor @Test func switchingSessionsReusesTheMetalViewAndRoutesNewInput() async throws {
    func waitFor(_ reason: Comment, until condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, reason)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func mountedCanvas(in view: PlatformView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        return view.subviews.lazy.compactMap { mountedCanvas(in: $0) }.first
    }

    let first = ControlledTransport(), second = ControlledTransport()
    let a = TerminalSession(openTransport: { _ in first })
    let b = TerminalSession(openTransport: { _ in second })
    let selected = SelectedSession(a)
    let tab = SessionTab(selected: selected)
    let rect = CGRect(x: 0, y: 0, width: 440, height: 300)
    #if os(macOS)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: tab)
    host.sizingOptions = []
    let window = SelectedTabWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let root = host
    #else
    let host = UIHostingController(rootView: tab)
    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
        ?? UIWindow(frame: rect)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    host.view.layoutIfNeeded()
    let root = host.view!
    #endif

    try await waitFor("The public view mounted.") { mountedCanvas(in: root) != nil }
    let canvas = try #require(mountedCanvas(in: root))
    #if os(iOS)
    // Unhosted UIKit tests have no owning scene to send an activation notification.
    if window.windowScene == nil { canvas.sceneLifecycleChanged(UIScene.didActivateNotification) }
    #endif
    let view = canvas.terminal
    let size = try #require(view.gridSize)
    await first.emit("archived in A\r\nfirst shell" + String(repeating: "\r\n", count: size.rows - 1))
    try await waitFor("The first shell displayed.") { view.snapshot?.rows.first?.text == "first shell" && view.historyCount == 1 }
    #if os(macOS)
    let input = try #require(view.subviews.compactMap { $0 as? MacTerminalInput }.first)
    let type = { (text: String) in input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    #else
    let type = { (text: String) in view.phoneInput.insertText(text) }
    #endif
    type("a")
    try await waitFor("Input reached the first shell.") { await first.writes == [Data("a".utf8)] }
    view.selectWord(row: 0, column: 0)
    #expect(view.selectedText == "first")

    selected.session = b
    await second.emit("second shell")
    try await waitFor("The same native view displayed the second shell.") {
        view.snapshot?.rows.first?.text == "second shell"
    }
    #expect(mountedCanvas(in: root) === canvas && canvas.terminal === view)
    #expect(view.selectedText == nil && view.historyCount == 0)
    // Output arriving on the old, still-owned transport cannot change the selected tab.
    await first.emit("\u{1b}]2;hidden output\u{7} only in A")
    try await waitFor("The hidden shell received the late output.") { a.title == "hidden output" }
    type("b")
    try await waitFor("Input reached the second shell.") { await second.writes == [Data("b".utf8)] }
    #expect(await first.writes == [Data("a".utf8)])
    #expect(view.snapshot?.rows.first?.text == "second shell")
    try await a.close()
    try await b.close()
}
