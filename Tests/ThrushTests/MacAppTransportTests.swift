#if os(macOS)
import AppKit
import SwiftUI
import Synchronization
import Testing
@testable import Thrush

@MainActor private struct SessionTestView: View {
    let session: TerminalSession
    let shown: Bool

    private var terminalView: TerminalView {
        var terminalView = TerminalView(session)
        // Command-line windows may be occluded. SwiftUI still mounts and removes the actual view.
        terminalView.probe.assumesVisible = true
        return terminalView
    }

    var body: some View {
        if shown {
            terminalView
        } else {
            Color.clear
        }
    }
}

@MainActor private func terminal(in view: NSView) -> TerminalMetalView? {
    if let terminal = view as? TerminalMetalView { return terminal }
    return view.subviews.lazy.compactMap { terminal(in: $0) }.first
}

@MainActor private func waitForView(_ change: String, until condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        try #require(ContinuousClock.now < deadline, "Timed out waiting for \(change)")
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor @Test func remountedMacViewDisplaysOutputReadWhileRemoved() async throws {
    _ = NSApplication.shared
    let transport = ControlledTransport()
    let opens = Mutex<[Terminal.Size]>([])
    let session = TerminalSession(openTransport: { size in
        opens.withLock { $0.append(size) }
        return transport
    })
    let hostingView = NSHostingView(rootView: SessionTestView(session: session, shown: true))
    hostingView.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFront(nil)
    defer { window.close() }
    hostingView.layoutSubtreeIfNeeded()

    await transport.emit("first\r\n")
    try await waitForView("the first native grid") { terminal(in: hostingView)?.snapshot?.rows.first?.text == "first" }
    let firstView = try #require(terminal(in: hostingView))
    let measured = try #require(firstView.gridSize)
    #expect(measured.columns > 1 && measured.rows > 1)
    #expect(opens.withLock { $0 } == [measured])

    hostingView.rootView = SessionTestView(session: session, shown: false)
    hostingView.layoutSubtreeIfNeeded()
    try await waitForView("native view removal") { firstView.window == nil && terminal(in: hostingView) == nil }
    await transport.emit("\u{1b}]2;Hidden title\u{7}second")
    try await waitForView("output while unmounted") { session.title == "Hidden title" }
    #expect(await transport.closes == 0)

    hostingView.rootView = SessionTestView(session: session, shown: true)
    hostingView.layoutSubtreeIfNeeded()
    try await waitForView("the new native grid") {
        guard let view = terminal(in: hostingView), view !== firstView, let rows = view.snapshot?.rows else { return false }
        return rows.prefix(2).map(\.text) == ["first", "second"]
    }
    #expect(opens.withLock { $0 } == [measured])
    #expect(!session.hasEnded)
    try await session.close()
    #expect(await transport.closes == 1)
}

@MainActor @Test func shellThatOpensDuringTheSpinnerWaitLeavesNoSpinner() async throws {
    _ = NSApplication.shared
    let transport = ControlledTransport()
    let requested = Mutex(false)
    let opening = AsyncStream<Void>.makeStream()
    let session = TerminalSession(openTransport: { _ in
        requested.withLock { $0 = true }
        for await _ in opening.stream { break }
        return transport
    })
    let hostingView = NSHostingView(rootView: SessionTestView(session: session, shown: true))
    hostingView.sizingOptions = []
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    window.orderFront(nil)
    defer { window.close() }
    hostingView.layoutSubtreeIfNeeded()

    try await waitForView("the transport request") { requested.withLock { $0 } }
    try await Task.sleep(for: .milliseconds(50))
    // The shell opens while the main actor stays busy past the spinner's 200 ms wait, so the
    // spinner's wakeup runs after the first screen has already cancelled it.
    opening.continuation.yield()
    usleep(400_000)
    let view = try #require(terminal(in: hostingView))
    try await waitForView("the fresh shell") { view.snapshot != nil }
    try await Task.sleep(for: .milliseconds(100))
    #expect(view.cursorSpinnerFrameInWindow == nil)
    #expect(!view.subviews.contains { $0 is CursorSpinner })
    try await session.close()
}
#endif
