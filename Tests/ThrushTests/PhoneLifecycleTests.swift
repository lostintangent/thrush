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

    let terminal = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 402, height: 550))
    var terminalView = TerminalView(session)
    terminalView.preparedView = terminal
    let host = UIHostingController(rootView: terminalView)
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
    func mountedCanvas() -> CanvasView? {
        var ancestor = terminal.superview
        while let view = ancestor {
            if let canvas = view as? CanvasView { return canvas }
            ancestor = view.superview
        }
        return nil
    }
    try await waitFor("the mounted canvas") { mountedCanvas() != nil }
    let canvas = try #require(mountedCanvas())
    func deliver(_ name: Notification.Name) {
        if let scene = window.windowScene {
            NotificationCenter.default.post(name: name, object: scene)
        } else {
            // An unhosted XCTest process has no owning UIScene. Exercise the same
            // native notification handler the scene-filtered selector calls.
            canvas.sceneLifecycleChanged(name)
        }
    }

    deliver(UIScene.didActivateNotification)
    try await waitFor("the first ready socket") { await session.actor.state == .active }
    #expect(peer.opens == 1)
    #expect(peer.closes == 0)
    let prompt = "foreground shell"
    try peer.send(prompt, opcode: .binary)
    try await waitFor("the live shell's first row") { terminal.snapshot?.rows.first?.text == prompt }

    // Control Center briefly deactivates the scene and then dismisses, without
    // entering background. The mounted view pauses Metal and retains its live PTY.
    deliver(UIScene.willDeactivateNotification)
    #expect(canvas.isShellPresented)
    #expect(!canvas.isDrawingVisible)
    await Task.yield()
    deliver(UIScene.didActivateNotification)
    #expect(canvas.isDrawingVisible)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await session.actor.state == .active)
    #expect(peer.opens == 1)
    #expect(peer.closes == 0)

    deliver(UIScene.willDeactivateNotification)
    deliver(UIScene.didEnterBackgroundNotification)
    // Repeated notification and window layout must not produce another close.
    deliver(UIScene.didEnterBackgroundNotification)
    host.view.layoutIfNeeded()
    try await waitFor("the background close frame") { await session.actor.state == .idle && peer.closes == 1 }
    #expect(!canvas.isDrawingVisible)
    #expect(!canvas.isShellPresented)
    #expect(peer.opens == 1)

    peer.resumeNextAttachment = true
    deliver(UIScene.willEnterForegroundNotification)
    deliver(UIScene.didActivateNotification)
    try await waitFor("the resumed foreground socket") { await session.actor.state == .awaitingReplay && peer.opens == 2 }
    #expect(terminal.snapshot?.rows.first?.text == prompt)
    let output = "while hidden"
    try peer.send("\(prompt)\r\n\(output)", opcode: .binary)
    try await waitFor("the foreground replay") {
        await session.actor.state == .active && terminal.snapshot?.rows.dropFirst().first?.text == output
    }
    #expect(!session.hasEnded && peer.opens == 2 && peer.closes == 1)
}
#endif
