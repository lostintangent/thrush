import SwiftUI
import Testing
@testable import Thrush

@MainActor @Test func visiblePaneAnnouncesEachDelayedReconnectAndEndsOnlyOnce() async throws {
    func waitFor(_ reason: Comment, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), reason)
    }
    func label(in view: TerminalView) -> String? {
        let spinner = view.subviews.compactMap { $0 as? CursorSpinner }.first
        #if os(macOS)
        return spinner?.accessibilityLabel()
        #else
        return spinner?.accessibilityLabel
        #endif
    }

    let peer = try ShellTestPeer()
    defer { peer.stop() }
    peer.automaticallySendsReady = false
    try await waitFor("The peer is listening.") { peer.port != nil }
    let port = try #require(peer.port)
    let endpoint = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let sockets = URLSession(configuration: .ephemeral)
    defer { sockets.invalidateAndCancel() }
    let session = TerminalSession { _ in sockets.webSocketTask(with: endpoint) }
    var announcements: [String] = []
    var times: [ContinuousClock.Instant] = []
    let rect = CGRect(x: 0, y: 0, width: 440, height: 300)
    func surface() -> TerminalView {
        let view = TerminalView(frame: rect, device: nil)
        view.onAccessibilityAnnouncement = { message in
            announcements.append(message)
            times.append(.now)
        }
        return view
    }
    func pane(_ view: TerminalView) -> some View {
        var pane = TerminalPane(session)
        pane.preparedView = view
        pane.assumesVisibleForBenchmark = true
        return pane.id(ObjectIdentifier(view))
    }
    let view = surface()
    #if os(macOS)
    _ = NSApplication.shared
    let host = NSHostingView(rootView: pane(view))
    host.sizingOptions = []
    let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    #else
    let host = UIHostingController(rootView: pane(view))
    let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first.map(UIWindow.init(windowScene:))
        ?? UIWindow(frame: rect)
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    host.view.layoutIfNeeded()
    #endif

    try await waitFor("The initial spinner is labeled Connecting.") { label(in: view) == "Connecting" && peer.opens == 1 }
    #expect(announcements.isEmpty)
    try peer.send(#"{"type":"ready","resumed":false}"#, opcode: .text)
    let transcript = "keep reading"
    try peer.send(transcript, opcode: .binary)
    try await waitFor("The live screen is displayed.") { view.snapshot?.rows.first?.text == transcript && label(in: view) == nil }
    view.selectWord(row: 0, column: 0)
    for episode in 1...2 {
        let started = ContinuousClock.now
        let opens = peer.opens
        peer.drop()
        try await waitFor("Recovery exposes its own label and posts its announcement.") {
            label(in: view) == "Reconnecting" && announcements.count >= episode && peer.opens > opens
        }
        #expect(times[episode - 1] - started >= .milliseconds(200))
        peer.drop() // A failed retry is still the same reconnect episode.
        try await waitFor("A second retry socket opened.") { peer.opens == opens + 2 }
        #expect(announcements == Array(repeating: "Reconnecting", count: episode))
        try peer.send(#"{"type":"ready","resumed":true}"#, opcode: .text)
        try peer.send(transcript, opcode: .binary)
        try await waitFor("The replay restored the live pane.") { label(in: view) == nil }
        #expect(view.selectedText == "keep")
    }

    try peer.send(#"{"type":"exit"}"#, opcode: .text)
    try await waitFor("The shell end is announced.") { announcements.last == "Shell ended" }
    let reopened = surface()
    host.rootView = pane(reopened)
    try await waitFor("A new pane displays the ended session's final screen.") { reopened.snapshot?.rows.first?.text == transcript }
    #expect(announcements == ["Reconnecting", "Reconnecting", "Shell ended"])
}
