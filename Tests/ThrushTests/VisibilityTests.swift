#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
import ThrushCore
@testable import Thrush

@MainActor private struct VisibilityHost: View {
    let session: TerminalSession
    let shown: Bool
    let selected: Bool

    private var terminalView: TerminalView {
        var result = TerminalView(session, isActive: selected)
        result.assumesVisibleForBenchmark = true
        return result
    }

    var body: some View {
        if shown {
            terminalView
        } else {
            Color.clear
        }
    }
}

@MainActor @Test func viewAttachesOnlyWhilePresentedAndSelected() async throws {
    let opened = Mutex<[Terminal.Size]>([])
    let session = TerminalSession { measured in
        opened.withLock { $0.append(measured) }
        throw URLError(.cannotConnectToHost)
    }
    func attachments() -> [Terminal.Size] { opened.withLock { $0 } }
    let host = NSHostingView(rootView: VisibilityHost(session: session, shown: true, selected: false))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }

    func update(shown: Bool, selected: Bool) {
        host.rootView = VisibilityHost(session: session, shown: shown, selected: selected)
        host.layoutSubtreeIfNeeded()
    }
    func waitFor(_ predicate: () async -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            try #require(ContinuousClock.now < until, "The view did not finish its visibility transition.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(attachments().isEmpty)
    update(shown: true, selected: true)
    try await waitFor { !attachments().isEmpty && attachments()[0].columns > 1 }
    update(shown: true, selected: false)
    try await waitFor { await session.actor.state == .idle }
    let first = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == first)
    update(shown: true, selected: true)
    try await waitFor { attachments().count > first.count }
    update(shown: false, selected: true)
    try await waitFor { await session.actor.state == .idle }
    let removed = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == removed)
}
#endif

#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
#endif

@MainActor @Test func hiddenDrawingCoalescesOutputAndRetainsTheNativeReader() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 402, height: 370))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var terminal = Terminal(size: .init(columns: 40, rows: 10))
    _ = terminal.receive("Build running\r\n".utf8)
    view.display(terminal)
    let initial = try #require(view.snapshot?.generation)
    let submissions = view.submissionCount
    view.setDrawingVisible(false)
    for line in 1...60 {
        _ = terminal.receive("Completed step \(line)\r\n".utf8)
        view.display(terminal)
    }
    #expect(view.snapshot?.generation == initial)
    #expect(view.submissionCount == submissions)
    view.setDrawingVisible(true)
    #expect(view.snapshot?.generation == terminal.snapshot().generation)
    #expect(view.snapshot?.rows.contains { $0.text == "Completed step 60" } == true)
}
