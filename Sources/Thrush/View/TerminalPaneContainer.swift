import SwiftUI
import ThrushCore

#if os(macOS)
import AppKit
typealias PaneNativeView = NSView
#else
import UIKit
typealias PaneNativeView = UIView
#endif

/// Keeps the grid inside the window's safe area and above the iPhone keyboard.
@MainActor final class TerminalPaneContainer: PaneNativeView {
    let terminal: TerminalView
    var onVisibility: (() -> Void)?
    #if os(macOS)
    private weak var closingWindow: NSWindow?
    #else
    private var sceneState: UIScene.ActivationState?
    private var visibilityObservations: [NSKeyValueObservation] = []
    #endif

    /// The scheme of the background the pane draws.
    private(set) var canvasScheme: ColorScheme?
    #if os(iOS)
    /// The scheme that keeps a navigation bar over the pane readable, or nil when none overlaps it.
    private(set) var barScheme: ColorScheme?
    #else
    /// A Mac toolbar's title follows the window's appearance, so an opposite canvas stops beneath it.
    private let toolbarCover = PaneNativeView()
    var toolbarCoverColor: CGColor? { toolbarCover.isHidden ? nil : toolbarCover.layer?.backgroundColor }
    #endif
    var onCanvasChange: (() -> Void)?

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        toolbarCover.wantsLayer = true
        toolbarCover.isHidden = true
        let bottom = safeAreaLayoutGuide.bottomAnchor
        #else
        let bottom = keyboardLayoutGuide.topAnchor
        #endif
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottom),
        ])

        #if os(macOS)
        addSubview(toolbarCover)
        toolbarCover.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbarCover.topAnchor.constraint(equalTo: topAnchor),
            toolbarCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarCover.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
        #endif
        terminal.onBackgroundChange = { [weak self] in self?.updateBacking() }

        let center = NotificationCenter.default
        #if os(macOS)
        let notifications = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                             NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification]
        #else
        let notifications = [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                             UIScene.willEnterForegroundNotification, UIScene.didEnterBackgroundNotification,
                             UIScene.didDisconnectNotification]
        #endif
        for name in notifications {
            center.addObserver(self, selector: #selector(lifecycleChanged(_:)), name: name, object: nil)
        }
        updateBacking()
    }

    required init?(coder: NSCoder) { nil }

    var isShellPresented: Bool {
        #if os(macOS)
        guard let window else { return false }
        return window !== closingWindow && !isHiddenOrHasHiddenAncestor
        #else
        guard let window else { return false }
        let state = sceneState ?? window.windowScene?.activationState
        guard state == .foregroundActive || state == .foregroundInactive else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha == 0 { return false }
            ancestor = view.superview
        }
        return true
        #endif
    }

    var isDrawingVisible: Bool {
        guard isShellPresented, let window else { return false }
        #if os(macOS)
        return !NSApp.isHidden && window.isVisible && !window.isMiniaturized
            && window.occlusionState.contains(.visible)
        #else
        return (sceneState ?? window.windowScene?.activationState) == .foregroundActive
        #endif
    }

    /// Whether keystrokes reach the terminal: its input is first responder in the key window of the
    /// active app on Mac, or in the active foreground scene on iPhone.
    var hasKeyboardFocus: Bool {
        guard isShellPresented, terminal.hasInputFocus, let window else { return false }
        #if os(macOS)
        return NSApp.isActive && window.isKeyWindow
        #else
        return (sceneState ?? window.windowScene?.activationState) == .foregroundActive
        #endif
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        closingWindow = nil
        onVisibility?()
    }
    override func viewDidHide() { super.viewDidHide(); onVisibility?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibility?() }
    override func layout() { super.layout(); updateSchemes() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateSchemes() }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneState = nil
        observeVisibility()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeVisibility()
    }

    private func observeVisibility() {
        visibilityObservations.removeAll()
        if window != nil {
            // UIKit sends no didMoveToWindow when a mounted ancestor is hidden.
            var ancestor: UIView? = self
            while let view = ancestor {
                visibilityObservations.append(view.observe(\.isHidden) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.onVisibility?() }
                })
                visibilityObservations.append(view.observe(\.alpha) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.onVisibility?() }
                })
                ancestor = view.superview
            }
        }
        onVisibility?()
    }

    override func layoutSubviews() { super.layoutSubviews(); updateSchemes() }

    // During willDeactivate / willEnterForeground the scene can still report the old state.
    func sceneLifecycleChanged(_ name: Notification.Name) {
        switch name {
        case UIScene.didActivateNotification: sceneState = .foregroundActive
        case UIScene.willDeactivateNotification, UIScene.willEnterForegroundNotification: sceneState = .foregroundInactive
        case UIScene.didEnterBackgroundNotification: sceneState = .background
        case UIScene.didDisconnectNotification: sceneState = .unattached
        default: return
        }
        onVisibility?()
    }
    #endif

    @objc private func lifecycleChanged(_ notification: Notification) {
        #if os(macOS)
        if let affected = notification.object as? NSWindow {
            guard affected === window else { return }
            if notification.name == NSWindow.willCloseNotification { closingWindow = affected }
            if notification.name == NSWindow.didBecomeKeyNotification { closingWindow = nil }
        }
        onVisibility?()
        #else
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        sceneLifecycleChanged(notification.name)
        #endif
    }

    /// The area outside the grid follows the program. An overlapping Mac toolbar may need the host theme.
    private func updateBacking() {
        let background = terminal.color(.background).paneCGColor
        #if os(macOS)
        layer?.backgroundColor = background
        toolbarCover.layer?.backgroundColor = terminal.resolvedTheme.palette.background.paneCGColor
        #else
        backgroundColor = UIColor(cgColor: background)
        #endif
        updateSchemes()
    }

    private func updateSchemes() {
        let background = terminal.color(.background)
        let canvas: ColorScheme = background.isDark ? .dark : .light
        #if os(macOS)
        let window = (self.window?.effectiveAppearance ?? effectiveAppearance).bestMatch(from: [.aqua, .darkAqua])
        toolbarCover.isHidden = safeAreaInsets.top == 0 || background.isDark == (window == .darkAqua)
            || background == terminal.resolvedTheme.palette.background
        guard canvas != canvasScheme else { return }
        canvasScheme = canvas
        #else
        let bar = safeAreaInsets.top > 0 ? canvas : nil
        guard canvas != canvasScheme || bar != barScheme else { return }
        (canvasScheme, barScheme) = (canvas, bar)
        #endif
        onCanvasChange?()
    }
}

private extension Terminal.RGB {
    var paneCGColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

#if os(iOS)
extension TerminalView {
    package var paneGeometryInWindow: (frame: CGRect, safeArea: CGRect, firstCell: CGRect)? {
        guard let pane = superview as? TerminalPaneContainer, let window else { return nil }
        return (pane.convert(pane.bounds, to: window),
                pane.convert(pane.safeAreaLayoutGuide.layoutFrame, to: window),
                convert(cellRect(row: 0, column: 0), to: window))
    }
}
#endif
