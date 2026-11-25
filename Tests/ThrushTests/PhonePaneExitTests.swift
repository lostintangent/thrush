#if os(iOS)
import Testing
import ThrushCore
import UIKit
@testable import Thrush

@MainActor @Test func newShellIsHittableAfterReplacementAndKeyboardDismissal() async throws {
    let terminal = TerminalView(frame: .zero)
    let pane = TerminalPaneContainer(terminal: terminal)
    let controller = UIViewController()
    controller.view = pane
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    pane.traitOverrides.preferredContentSizeCategory = .large
    pane.sceneLifecycleChanged(UIScene.didActivateNotification)
    let pixel = 1 / max(1, pane.traitCollection.displayScale)

    func settle() async throws {
        window.layoutIfNeeded()
        // UIKit's notice crossfade takes 120 ms. Inspect the settled native hit target.
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
    }
    func statusButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == "terminal.status.action" { return button }
        for child in view.subviews {
            if let button = statusButton(in: child) { return button }
        }
        return nil
    }
    func checkAction(_ label: String) throws -> UIButton {
        let surface = try #require(pane.mountedNoticeView)
        let backing = try #require(pane.mountedNoticeBacking)
        let button = try #require(statusButton(in: surface))
        #expect(button.accessibilityLabel == label && button.isEnabled)
        #expect(button.accessibilityTraits.contains(.button))
        #expect(button.bounds.width >= 44 && button.bounds.height >= 44)
        #expect(surface.bounds.insetBy(dx: -pixel, dy: -pixel).contains(button.convert(button.bounds, to: surface)))
        #expect(abs(backing.frame.minX - pane.bounds.minX) <= pixel && abs(backing.frame.maxX - pane.bounds.maxX) <= pixel)
        #expect(abs(backing.frame.minY - surface.frame.minY) <= pixel && abs(backing.frame.maxY - pane.bounds.maxY) <= pixel)
        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: window)
        let hit = window.hitTest(point, with: nil)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
        return button
    }

    pane.show(.exited)
    try await settle()
    _ = try checkAction("New Shell")
    let directHeight = try #require(pane.mountedNoticeView?.bounds.height)
    let directBacking = try #require(pane.mountedNoticeBacking?.frame)
    let hiddenKeyboardHeight = pane.keyboardLayoutGuide.layoutFrame.height
    pane.show(nil)
    try await settle()

    var activations: [PaneNotice] = []
    pane.onAction = {
        if let current = pane.current { activations.append(current) }
        pane.show(nil)
    }
    pane.show(.displaced)
    try await settle()
    try checkAction("Use shell in this window").sendActions(for: .touchUpInside)
    #expect(activations == [.displaced])
    try await settle()

    pane.sceneLifecycleChanged(UIScene.willDeactivateNotification)
    pane.sceneLifecycleChanged(UIScene.didEnterBackgroundNotification)
    pane.sceneLifecycleChanged(UIScene.willEnterForegroundNotification)
    pane.sceneLifecycleChanged(UIScene.didActivateNotification)
    pane.show(.connecting(retainingTranscript: true))
    try await settle()
    let connectingHeight = try #require(pane.mountedNoticeView?.bounds.height)

    terminal.setInputAvailability(.live, dismissKeyboard: false)
    #expect(terminal.focusInput())
    // An unhosted test window has a first responder but no onscreen keyboard.
    // Move its actual keyboard layout guide to the replacement capture's 345 pt boundary.
    controller.additionalSafeAreaInsets.bottom = 345 - hiddenKeyboardHeight
    pane.show(.replacement(discardedInput: false))
    try await settle()
    #expect(abs(pane.keyboardLayoutGuide.layoutFrame.height - 345) <= pixel)
    let replacementHeight = try #require(pane.mountedNoticeView?.bounds.height)
    #expect(replacementHeight > connectingHeight)

    var bytes: [UInt8] = []
    let screen = Terminal(size: .init(columns: 47, rows: 25))
    terminal.onInput = { bytes.append(contentsOf: screen.encode($0)) }
    terminal.phoneInput.insertText("exit")
    terminal.phoneInput.insertText("\n")
    #expect(bytes == Array("exit\r".utf8))
    terminal.setInputAvailability(.blocked, dismissKeyboard: true)
    controller.additionalSafeAreaInsets.bottom = 0
    pane.show(.exited)
    try await settle()
    #expect(!terminal.phoneInput.isFirstResponder)
    #expect(abs(pane.keyboardLayoutGuide.layoutFrame.height - hiddenKeyboardHeight) <= pixel)
    func checkRestoredAction() throws -> UIButton {
        let surface = try #require(pane.mountedNoticeView)
        let backing = try #require(pane.mountedNoticeBacking)
        #expect(abs(surface.bounds.height - directHeight) <= pixel)
        #expect(abs(backing.frame.height - directBacking.height) <= pixel)
        return try checkAction("New Shell")
    }
    try checkRestoredAction().sendActions(for: .touchUpInside)
    #expect(activations == [.displaced, .exited])

    // The replacement and natural exit can arrive in one layout cycle or during a dismissal.
    pane.show(.connecting(retainingTranscript: true))
    try await settle()
    pane.show(.replacement(discardedInput: true))
    pane.show(.exited)
    try await settle()
    _ = try checkRestoredAction()
    pane.show(.closed)
    try await settle()
    pane.show(nil)
    pane.show(.exited)
    try await settle()
    try checkRestoredAction().sendActions(for: .touchUpInside)
    #expect(activations == [.displaced, .exited, .exited])
}
#endif
