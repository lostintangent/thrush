#if os(iOS)
import Foundation
import Network
import SwiftUI
import Testing
import UIKit
@testable import Thrush

@MainActor @Test func iPhoneSceneInterruptionKeepsItsSocketUntilBackground() async throws {
    func waitFor(_ label: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for \(label).")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    let peer = try ShellTestPeer()
    defer { peer.stop() }
    try await waitFor("the loopback peer") { (peer.port ?? 0) > 0 }
    let port = try #require(peer.port)
    let address = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let urlSession = URLSession(configuration: .ephemeral)
    defer { urlSession.invalidateAndCancel() }
    let session = TerminalSession { _ in
        urlSession.webSocketTask(with: address)
    }

    let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 550))
    var pane = TerminalPane(session)
    pane.preparedView = terminal
    let host = UIHostingController(rootView: pane)
    let window: UIWindow
    if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
        window = UIWindow(windowScene: scene)
    } else {
        window = UIWindow(frame: terminal.bounds)
    }
    window.rootViewController = host
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    host.view.setNeedsLayout()
    host.view.layoutIfNeeded()
    func mountedPane() -> TerminalPaneContainer? {
        var ancestor = terminal.superview
        while let view = ancestor {
            if let container = view as? TerminalPaneContainer { return container }
            ancestor = view.superview
        }
        return nil
    }
    try await waitFor("the mounted terminal pane") { mountedPane() != nil }
    let container = try #require(mountedPane())
    func deliver(_ name: Notification.Name) {
        if let scene = window.windowScene {
            NotificationCenter.default.post(name: name, object: scene)
        } else {
            // An unhosted XCTest process has no owning UIScene. Exercise the same
            // native notification handler the scene-filtered selector calls.
            container.sceneLifecycleChanged(name)
        }
    }

    deliver(UIScene.didActivateNotification)
    try await waitFor("the first ready socket") { await session.connection.state == .active }
    #expect(peer.opens == 1)
    #expect(peer.closes == 0)

    // Control Center briefly deactivates the scene and then dismisses, without
    // entering background. The mounted pane pauses Metal and retains its live PTY.
    deliver(UIScene.willDeactivateNotification)
    #expect(container.isShellPresented)
    #expect(!container.isDrawingVisible)
    await Task.yield()
    deliver(UIScene.didActivateNotification)
    #expect(container.isDrawingVisible)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await session.connection.state == .active)
    #expect(peer.opens == 1)
    #expect(peer.closes == 0)

    deliver(UIScene.willDeactivateNotification)
    deliver(UIScene.didEnterBackgroundNotification)
    // Repeated notification and window layout must not produce another close.
    deliver(UIScene.didEnterBackgroundNotification)
    host.view.layoutIfNeeded()
    try await waitFor("the background close frame") { await session.connection.state == .detached && peer.closes == 1 }
    #expect(!container.isDrawingVisible)
    #expect(!container.isShellPresented)
    #expect(peer.opens == 1)

    deliver(UIScene.willEnterForegroundNotification)
    deliver(UIScene.didActivateNotification)
    try await waitFor("the foreground reattachment") { await session.connection.state == .active && peer.opens == 2 }
    #expect(peer.closes == 1)
}
#endif
