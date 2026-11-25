#if os(macOS)
import AppKit
import SwiftUI
import Synchronization
import Testing
@testable import Thrush

@MainActor private struct StreamPaneHost: View {
    let session: TerminalSession
    let shown: Bool

    private var pane: TerminalPane {
        var pane = TerminalPane(session)
        // Command-line windows may be occluded. SwiftUI still mounts and removes the actual pane.
        pane.assumesVisibleForBenchmark = true
        return pane
    }

    var body: some View {
        if shown {
            pane
        } else {
            Color.clear
        }
    }
}

@MainActor private func terminal(in view: NSView) -> TerminalView? {
    if let terminal = view as? TerminalView { return terminal }
    return view.subviews.lazy.compactMap { terminal(in: $0) }.first
}

@MainActor private func waitForPane(_ change: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(change)")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test func remountedMacPaneDisplaysOutputReadWhileRemoved() async throws {
    _ = NSApplication.shared
    let stream = ControlledTransport()
    let opens = Mutex<[Terminal.Size]>([])
    let session = TerminalSession(openTransport: { size in
        opens.withLock { $0.append(size) }
        return stream
    })
    let host = NSHostingView(rootView: StreamPaneHost(session: session, shown: true))
    host.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()

    await stream.emit("first\r\n")
    try await waitForPane("the first native grid") { terminal(in: host)?.snapshot?.rows.first?.text == "first" }
    let firstView = try #require(terminal(in: host))
    let measured = try #require(firstView.gridSize)
    #expect(measured.columns > 1 && measured.rows > 1)
    #expect(opens.withLock { $0 } == [measured])

    host.rootView = StreamPaneHost(session: session, shown: false)
    host.layoutSubtreeIfNeeded()
    try await waitForPane("native view removal") { firstView.window == nil && terminal(in: host) == nil }
    await stream.emit("\u{1b}]2;Hidden title\u{7}second")
    try await waitForPane("output while unmounted") { session.title == "Hidden title" }
    #expect(await stream.closes == 0)

    host.rootView = StreamPaneHost(session: session, shown: true)
    host.layoutSubtreeIfNeeded()
    try await waitForPane("the new native grid") {
        guard let view = terminal(in: host), view !== firstView, let rows = view.snapshot?.rows else { return false }
        return rows.prefix(2).map(\.text) == ["first", "second"]
    }
    #expect(opens.withLock { $0 } == [measured])
    #expect(!session.hasEnded)
    try await session.close()
    #expect(await stream.closes == 1)
}
#endif
