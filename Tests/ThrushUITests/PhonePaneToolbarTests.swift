#if os(iOS)
import SwiftUI
import Testing
import ThrushConnection
@testable import ThrushUI
import UIKit

@MainActor @Test func navigationToolbarOverlaysThePaneButClearsRowOne() async throws {
    let url = try #require(URL(string: "ws://127.0.0.1:1/socket"))
    let connection = TerminalConnection(clientID: "toolbar-layout") { _, _ in URLSession.shared.webSocketTask(with: url) }
    let host = UIHostingController(rootView: NavigationStack {
        TerminalPane(connection)
            .ignoresSafeArea()
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") {} } }
    })
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        window = UIWindow(windowScene: scene)
    } else {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    }
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    func descendant<V: UIView>(_ type: V.Type, in view: UIView) -> V? {
        if let match = view as? V { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while descendant(TerminalPaneContainer.self, in: window) == nil || descendant(UINavigationBar.self, in: window) == nil {
        try #require(ContinuousClock.now < end, "The native navigation bar and pane must mount in the window.")
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(25))
    }
    let pane = try #require(descendant(TerminalPaneContainer.self, in: window))
    let bar = try #require(descendant(UINavigationBar.self, in: window))
    pane.show(.connecting(retainingTranscript: false))
    window.layoutIfNeeded()
    let frame = pane.convert(pane.bounds, to: window)
    let nav = bar.convert(bar.bounds, to: window)
    let grid = pane.terminal.convert(pane.terminal.bounds, to: window)
    let first = pane.terminal.convert(pane.terminal.cellRect(row: 0, column: 0), to: window)
    let noticeView = try #require(pane.mountedNoticeView)
    let notice = noticeView.convert(noticeView.bounds, to: window)
    #expect(nav.height > 0 && grid.height > 0)
    #expect(abs(frame.minY - window.bounds.minY) < 1)
    #expect(abs(frame.width - window.bounds.width) < 1)
    #expect(grid.minY >= nav.maxY - 1, "grid \(grid), navigation bar \(nav), pane \(frame)")
    #expect(first.minY >= nav.maxY - 1 && first.height > 0)
    #expect(notice.minY >= nav.maxY)
    #expect(abs(notice.midY - (nav.maxY + grid.maxY) / 2) <= 1)

    pane.show(.displaced)
    window.layoutIfNeeded()
    let backing = try #require(pane.mountedNoticeBacking)
    let strip = backing.convert(backing.bounds, to: window)
    #expect(abs(strip.minX - frame.minX) < 1 && abs(strip.maxX - frame.maxX) < 1)
}
#endif
