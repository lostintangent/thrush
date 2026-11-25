#if os(iOS)
import Testing
import Thrush
import UIKit
@testable import ThrushUI

@MainActor @Test func accessibilityTextKeepsThePaneActionReachableAndTranscriptElementsStable() async throws {
    // A keyboard-open iPhone 17 in landscape has 178 pt for the terminal. A full
    // UIKit window exercises the SwiftUI notice's actual intrinsic size and scrolling.
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 874, height: 402))
    let terminal = TerminalView(frame: window.bounds)
    let pane = TerminalPaneContainer(terminal: terminal)
    // Keep the measured usable surface clear of the unhosted window's own safe areas.
    pane.frame = CGRect(x: 62, y: 90, width: 750, height: 178)
    window.addSubview(pane)
    window.isHidden = false
    pane.sceneLifecycleChanged(UIScene.didActivateNotification)
    defer { window.isHidden = true }
    func settle() async throws {
        pane.setNeedsLayout()
        pane.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(160))
        pane.layoutIfNeeded()
    }
    func find<View: UIView>(_ type: View.Type, in root: UIView, where matches: (View) -> Bool) -> View? {
        if let view = root as? View, matches(view) { return view }
        for child in root.subviews {
            if let result = find(type, in: child, where: matches) { return result }
        }
        return nil
    }

    try await settle()
    let size = try #require(terminal.gridSize)
    #expect(size.rows == 9)
    var screen = Terminal(size: size)
    _ = screen.receive("Known accessible line\r\nFinal output\r\n".utf8)
    terminal.display(screen)
    let reader = try #require(find(PhoneTranscriptView.self, in: terminal, where: { _ in true }))
    func knownLine() -> UIAccessibilityElement? {
        (reader.accessibilityElements ?? []).compactMap { $0 as? UIAccessibilityElement }
            .first { $0.accessibilityLabel == "Known accessible line" }
    }
    let original = try #require(knownLine())
    var firstFont: CGFloat = 0
    for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
        pane.traitOverrides.preferredContentSizeCategory = category
        for notice in [PaneNotice.displaced, .exited] {
            terminal.theme = notice == .displaced ? .slateDark : .slateLight
            pane.show(notice)
            try await settle()
            let surface = try #require(pane.mountedNoticeView)
            let button = try #require(find(UIButton.self, in: surface) {
                $0.accessibilityIdentifier == "terminal.status.action" && $0.window != nil
            })
            #expect(button.accessibilityLabel == notice.actionLabel)
            #expect(button.accessibilityHint == notice.actionHint)
            let caption = try #require(notice.action)
            #expect(button.accessibilityUserInputLabels == [caption])
            #expect(button.accessibilityTraits.contains(.button))
            #expect(button.bounds.width >= 44 && button.bounds.height >= 44)
            #expect(knownLine() === original)
            let expectedColor = UIColor(terminalColor: terminal.resolvedTheme.hostBacking)
            let backing = try #require(find(UIView.self, in: pane) {
                $0 !== pane && $0.backgroundColor?.isEqual(expectedColor) == true && !$0.isHidden
            })
            #expect(backing.backgroundColor?.cgColor.alpha == 1)

            let font = try #require(button.titleLabel?.font.pointSize)
            if category == .large {
                firstFont = font
            } else {
                #expect(font > firstFont * 1.5)
            }
            var ancestor = button.superview
            while let view = ancestor, view !== surface {
                if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height {
                    scroll.scrollRectToVisible(button.convert(button.bounds, to: scroll), animated: false)
                    scroll.layoutIfNeeded()
                }
                ancestor = view.superview
            }
            await Task.yield()
            pane.layoutIfNeeded()
            let frame = button.convert(button.bounds, to: surface)
            print("AX layout: category=\(category.rawValue) notice=\(notice.title) terminal=\(terminal.bounds) surface=\(surface.bounds) button=\(frame) font=\(font)")
            #expect(surface.bounds.insetBy(dx: -1, dy: -1).contains(frame))
            let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: pane)
            func hitsAction() -> Bool {
                let hit = pane.hitTest(center, with: nil)
                return hit === button || hit?.isDescendant(of: button) == true
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !hitsAction(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(hitsAction())
            pane.show(notice)
            #expect(pane.mountedNoticeView === surface)
            #expect(knownLine() === original)
        }
    }
    pane.show(.reconnecting)
    try await settle()
    let reconnect = try #require(pane.mountedNoticeView)
    if UIAccessibility.isReduceMotionEnabled {
        #expect(find(UIActivityIndicatorView.self, in: reconnect, where: { $0.isAnimating }) == nil)
        #expect(reconnect.layer.animation(forKey: "opacity") == nil)
    }
    print("Accessibility settings: Reduce Motion=\(UIAccessibility.isReduceMotionEnabled) Reduce Transparency=\(UIAccessibility.isReduceTransparencyEnabled) System size=\(window.traitCollection.preferredContentSizeCategory.rawValue)")
    pane.show(nil)
    if UIAccessibility.isReduceMotionEnabled { #expect(pane.mountedNoticeView == nil) }
}
#endif
