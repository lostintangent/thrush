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
    private let viewport = UIView()
    private var gridConstraints: [NSLayoutConstraint] = []
    private var rotationConstraints: [NSLayoutConstraint] = []
    private var heldCursor: (top: NSLayoutConstraint, row: Int, rows: Int, history: Int)?
    var viewportSize: CGSize { viewport.bounds.size }

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
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
        addSubview(toolbarCover)
        toolbarCover.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbarCover.topAnchor.constraint(equalTo: topAnchor),
            toolbarCover.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarCover.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarCover.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
        #else
        addSubview(viewport)
        viewport.clipsToBounds = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        gridConstraints = [
            terminal.topAnchor.constraint(equalTo: viewport.topAnchor),
            terminal.heightAnchor.constraint(equalTo: viewport.heightAnchor),
        ]
        // Before UIKit supplies a keyboard frame, its top anchor can be unconstrained.
        // Prefer the safe bottom until the keyboard guide determines the viewport height.
        let safeBottom = viewport.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor)
        safeBottom.priority = .defaultLow
        NSLayoutConstraint.activate(gridConstraints + [
            safeBottom,
            viewport.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
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

    // Keep the source drawable at its native height while the keyboard clips its viewport.
    // A reader in history keeps the top row. At the live edge the cursor waits on the row the
    // resized grid will give it, so the first resized frame draws the prompt where it already is.
    func beginRotation(sourceHeight: CGFloat? = nil) {
        guard rotationConstraints.isEmpty else { return }
        terminal.holdsGridGeometry = true
        let top = terminal.topAnchor.constraint(equalTo: viewport.topAnchor)
        rotationConstraints = [terminal.heightAnchor.constraint(equalToConstant: sourceHeight ?? terminal.bounds.height), top]
        if terminal.historyOffset == 0, let snapshot = terminal.snapshot {
            heldCursor = (top, snapshot.cursorRow, snapshot.size.rows, snapshot.currentShellHistoryCount)
        }
        NSLayoutConstraint.deactivate(gridConstraints)
        NSLayoutConstraint.activate(rotationConstraints)
    }

    func endRotation() {
        guard !rotationConstraints.isEmpty else { return }
        NSLayoutConstraint.deactivate(rotationConstraints)
        rotationConstraints.removeAll()
        heldCursor = nil
        NSLayoutConstraint.activate(gridConstraints)
        layoutIfNeeded()
        terminal.holdsGridGeometry = false
    }

    override func layoutSubviews() {
        let turning = turnMovesViewport ? (frame: viewport.frame, presented: viewport.layer.presentation()) : nil
        super.layoutSubviews()
        if let turning, let presented = turning.presented, viewport.frame != turning.frame,
           UIView.inheritedAnimationDuration == 0 {
            easeViewportIntoTurn(from: turning.frame, presented: presented)
        }
        alignHeldCursor()
        updateSchemes()
    }

    private var turnMovesViewport: Bool {
        !rotationConstraints.isEmpty || viewport.layer.animation(forKey: "turn bounds.size.height") != nil
    }

    // UIKit turns the pane with additive animations, so a keyboard guide that moves the viewport
    // mid-turn without one shifts it by the whole change at once. A shorter viewport can then
    // present shorter than any frame it had and clip the terminal away. Instead, the change eases
    // in on the turn's own curve: an offset that starts at the full change and shrinks with the
    // part of the turn still ahead, so the viewport reaches its new frame as the turn ends.
    // The keyboard can animate the viewport's height alongside the turn, but only the turn
    // changes its width.
    private func easeViewportIntoTurn(from previous: CGRect, presented: CALayer) {
        let layer = viewport.layer
        func turned(_ animation: CABasicAnimation) -> CGFloat {
            guard animation.keyPath == "bounds.size", animation.isAdditive else { return 0 }
            return (animation.fromValue as? NSValue)?.cgSizeValue.width ?? 0
        }
        guard let turn = (layer.animationKeys() ?? []).compactMap({ layer.animation(forKey: $0) as? CABasicAnimation })
                .last(where: { turned($0) != 0 }) else { return }
        let ahead = (presented.bounds.width - layer.bounds.width) / turned(turn)
        guard ahead > 0.05 else { return }
        for (key, shift) in [("bounds.size.height", previous.height - layer.bounds.height),
                             ("position.y", previous.midY - layer.position.y)] {
            let easing = layer.animation(forKey: "turn " + key) as? CABasicAnimation
            let ease = turn.copy() as! CABasicAnimation
            ease.delegate = nil
            ease.keyPath = key
            ease.fromValue = (easing?.fromValue as? CGFloat ?? 0) + shift / ahead
            ease.toValue = 0
            layer.add(ease, forKey: "turn " + key)
        }
    }

    // Follows the emulator's resize: a shorter grid scrolls the cursor into view, and a taller
    // one pulls history back above a cursor on the bottom row.
    private func alignHeldCursor() {
        guard let held = heldCursor, let metrics = terminal.metrics else { return }
        let rows = metrics.size(in: viewport.bounds.size).rows
        let row = if rows < held.rows { min(held.row, rows - 1) }
            else if held.row == held.rows - 1 { held.row + min(held.history, rows - held.rows) }
            else { held.row }
        let constant = CGFloat((row - held.row) * metrics.rowHeightPixels) / metrics.scale
        if held.top.constant != constant { held.top.constant = constant }
    }

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
        guard let pane = superview?.superview as? TerminalPaneContainer, let window else { return nil }
        return (pane.convert(pane.bounds, to: window),
                pane.convert(pane.safeAreaLayoutGuide.layoutFrame, to: window),
                convert(cellRect(row: 0, column: 0), to: window))
    }
}
#endif
