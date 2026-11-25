#if os(iOS)
import Foundation
import Network
import SwiftUI
import Testing
import ThrushConnection
import UIKit
@testable import ThrushUI

/// Observe real WebSocket handshakes and close frames on the simulator's loopback
/// interface. A task cancel or a reconnect would be visible even if it recovered
/// before the test inspected the connection actor.
@MainActor private final class ScenePeer {
    private let listener: NWListener
    private var sockets: [NWConnection] = []
    private(set) var opens = 0
    private(set) var closes = 0

    init() throws {
        let options = NWParameters.tcp
        options.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        options.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: options)
        listener.newConnectionHandler = { [weak self] socket in
            MainActor.assumeIsolated { self?.accept(socket) }
        }
        listener.start(queue: .main)
    }

    var port: UInt16? { listener.port?.rawValue }

    private func accept(_ socket: NWConnection) {
        sockets.append(socket)
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard case .ready = state, let socket else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.opens += 1
                let message = NWConnection.ContentContext(identifier: "ready", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                socket.send(content: Data(#"{"type":"ready","resumed":false}"#.utf8), contentContext: message,
                            isComplete: true, completion: .idempotent)
                self.receive(socket)
            }
        }
        socket.start(queue: .main)
    }

    private func receive(_ socket: NWConnection) {
        socket.receiveMessage { [weak self] _, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ws = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if ws?.opcode == .close || error != nil {
                    self.closes += 1
                    socket.cancel()
                } else {
                    self.receive(socket)
                }
            }
        }
    }

    func stop() {
        listener.cancel()
        sockets.forEach { $0.cancel() }
    }
}

@MainActor @Test func iPhoneSceneInterruptionKeepsItsSocketUntilBackground() async throws {
    func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            try #require(ContinuousClock.now < deadline, "The pane did not finish its scene transition.")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    let peer = try ScenePeer()
    defer { peer.stop() }
    try await waitFor { peer.port != nil }
    let port = try #require(peer.port)
    let address = try #require(URL(string: "ws://127.0.0.1:\(port)/socket"))
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let connection = TerminalConnection(clientID: "scene-interruption") { _, _ in
        session.webSocketTask(with: address)
    }

    let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 402, height: 550))
    var pane = TerminalPane(connection)
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
    try await waitFor { terminal.superview is TerminalPaneContainer }
    let container = try #require(terminal.superview as? TerminalPaneContainer)
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
    try await waitFor { await connection.state == .active }
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
    #expect(await connection.state == .active)
    #expect(peer.opens == 1)
    #expect(peer.closes == 0)

    deliver(UIScene.willDeactivateNotification)
    deliver(UIScene.didEnterBackgroundNotification)
    // Repeated notification and window layout must not produce another close.
    deliver(UIScene.didEnterBackgroundNotification)
    host.view.layoutIfNeeded()
    try await waitFor { await connection.state == .detached && peer.closes == 1 }
    #expect(!container.isDrawingVisible)
    #expect(!container.isShellPresented)
    #expect(peer.opens == 1)

    deliver(UIScene.willEnterForegroundNotification)
    deliver(UIScene.didActivateNotification)
    try await waitFor { await connection.state == .active && peer.opens == 2 }
    #expect(peer.closes == 1)
}
#endif
