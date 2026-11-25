#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Synchronization
import Testing
import Thrush
import ThrushConnection
@testable import ThrushUI

@MainActor private struct VisibilityHost: View {
    let connection: TerminalConnection
    let shown: Bool
    let selected: Bool

    private var pane: TerminalPane {
        var result = TerminalPane(connection, isActive: selected)
        result.assumesVisibleForBenchmark = true
        return result
    }

    var body: some View {
        if shown {
            pane
        } else {
            Color.clear
        }
    }
}

@MainActor @Test func paneAttachesOnlyWhilePresentedAndSelected() async throws {
    let opened = Mutex<[Terminal.Size]>([])
    let connection = TerminalConnection(clientID: "visible-test") { _, measured in
        opened.withLock { $0.append(measured) }
        throw URLError(.cannotConnectToHost)
    }
    func attachments() -> [Terminal.Size] { opened.withLock { $0 } }
    let host = NSHostingView(rootView: VisibilityHost(connection: connection, shown: true, selected: false))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }

    func update(shown: Bool, selected: Bool) {
        host.rootView = VisibilityHost(connection: connection, shown: shown, selected: selected)
        host.layoutSubtreeIfNeeded()
    }
    func waitFor(_ predicate: () async -> Bool) async throws {
        let until = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            try #require(ContinuousClock.now < until, "The pane did not finish its visibility transition.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    try await Task.sleep(for: .milliseconds(100))
    #expect(attachments().isEmpty)
    update(shown: true, selected: true)
    try await waitFor { !attachments().isEmpty && attachments()[0].columns > 1 }
    update(shown: true, selected: false)
    try await waitFor { await connection.state == .detached }
    let first = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == first)
    update(shown: true, selected: true)
    try await waitFor { attachments().count > first.count }
    update(shown: false, selected: true)
    try await waitFor { await connection.state == .detached }
    let removed = attachments()
    try await Task.sleep(for: .milliseconds(350))
    #expect(attachments() == removed)
}
#endif
