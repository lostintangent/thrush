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
    var visible = true

    private var terminalView: some View {
        TerminalView(session, isActive: selected).environment(\.terminalProbe, .init(isVisible: visible))
    }

    var body: some View {
        if shown {
            terminalView
        } else {
            Color.clear
        }
    }
}

// A probe's visibility reaches the view on its own, so a harness can detach a view it doesn't own.
@MainActor @Test func viewAttachesOnlyWhilePresentedSelectedAndVisible() async throws {
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

    func update(shown: Bool, selected: Bool, visible: Bool = true) {
        host.rootView = VisibilityHost(session: session, shown: shown, selected: selected, visible: visible)
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
    update(shown: true, selected: true, visible: false)
    try await waitFor { await session.actor.state == .idle }
    let hidden = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == hidden)
    update(shown: true, selected: true)
    try await waitFor { attachments().count > hidden.count }
    update(shown: false, selected: true)
    try await waitFor { await session.actor.state == .idle }
    let removed = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == removed)
}

@MainActor @Test func probePreparesEachSessionBeforeTheViewAttachesIt() async throws {
    let log = Mutex<[String]>([])
    func session(_ name: String) -> TerminalSession {
        TerminalSession { _ in
            log.withLock { $0.append("open " + name) }
            throw URLError(.cannotConnectToHost)
        }
    }
    let first = session("first"), second = session("second")
    let probe = TerminalView.Probe(isVisible: true, prepare: { prepared in
        let name = prepared === first ? "first" : "second"
        log.withLock { $0.append("prepare " + name) }
        try? await Task.sleep(for: .milliseconds(50))
        log.withLock { $0.append("prepared " + name) }
    })
    func root(_ session: TerminalSession) -> AnyView { AnyView(TerminalView(session).environment(\.terminalProbe, probe)) }
    let host = NSHostingView(rootView: root(first))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    func waitFor(_ entry: String) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !log.withLock({ $0.contains(entry) }) {
            try #require(ContinuousClock.now < until, "The view never logged \(entry).")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    try await waitFor("open first")
    host.rootView = root(second)
    host.layoutSubtreeIfNeeded()
    try await waitFor("open second")
    let entries = log.withLock { $0 }
    for name in ["first", "second"] {
        let prepared = try #require(entries.firstIndex(of: "prepared " + name))
        #expect(prepared < entries.firstIndex(of: "open " + name)!)
        #expect(entries.filter { $0 == "prepare " + name }.count == 1)
    }
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
    _ = terminal.write("Build running\r\n".utf8)
    view.display(terminal)
    let initial = try #require(view.snapshot?.generation)
    let submissions = view.submissionCount
    view.setDrawingVisible(false)
    for line in 1...60 {
        _ = terminal.write("Completed step \(line)\r\n".utf8)
        view.display(terminal)
    }
    #expect(view.snapshot?.generation == initial)
    #expect(view.submissionCount == submissions)
    view.setDrawingVisible(true)
    #expect(view.snapshot?.generation == terminal.snapshot().generation)
    #expect(view.snapshot?.rows.contains { $0.text == "Completed step 60" } == true)
}
