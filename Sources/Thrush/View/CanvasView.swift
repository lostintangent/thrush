import SwiftUI
import ThrushCore

#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// The terminal view's canvas. Its background reaches under every bar and safe area, while it keeps the
/// Metal view's grid inside the window's safe area and above the iPhone keyboard. With the iPhone keyboard
/// down, the grid runs on into the home indicator's strip.
@MainActor final class CanvasView: PlatformView {
    let terminal: TerminalMetalView
    var onVisibility: (() -> Void)?
    #if os(macOS)
    private weak var closingWindow: NSWindow?
    #else
    // Clips the Metal view to where the viewport shows: inside the safe area at the sides and top, and down to
    // the keyboard, or the canvas's bottom edge while the keyboard is down.
    private let viewport = UIView()
    private var gridConstraints: [NSLayoutConstraint] = []
    private var holdConstraints: [NSLayoutConstraint] = []
    private var held: (top: NSLayoutConstraint, cursor: Int, rows: Int, history: Int, offset: Int, keyboard: Bool)?
    // A hold can slide rows under the grid's top inset or below the resized grid's last row,
    // where the resized grid leaves the canvas blank.
    private let insetCover = UIView()
    private let bottomCover = UIView()
    private var insetHeight: NSLayoutConstraint!
    private var gridBottom: NSLayoutConstraint!
    private var keyboardEdge: NSLayoutConstraint!
    private var pinnedHeight: NSLayoutConstraint!
    var viewportSize: CGSize { viewport.bounds.size }
    var guideShowsKeyboard: Bool { keyboardLayoutGuide.layoutFrame.height > safeAreaInsets.bottom + 1 }

    private var sceneState: UIScene.ActivationState?
    private var visibilityObservations: [NSKeyValueObservation] = []
    #endif

    #if os(iOS)
    /// The scheme that keeps a navigation bar over the canvas readable, or nil when none overlaps it.
    private(set) var barScheme: ColorScheme?
    var onBarSchemeChange: (() -> Void)?
    #else
    /// The title bar of the full-size window toolbar the canvas runs under, which takes the canvas's appearance
    /// while it's opposite the window's, as a navigation bar takes its scheme on iPhone.
    private weak var titlebar: NSView?
    /// Whether everything in the title bar over the canvas took the appearance the canvas last asked for.
    private var titlebarFollows: (dark: Bool, follows: Bool)?
    /// The pending check that the title bar followed, which tests await rather than guess when it runs.
    private(set) var titlebarCheck: Task<Void, Never>?
    /// The canvas that set each title bar's appearance, so a canvas leaving it clears only its own.
    private static let titlebarOwners = NSMapTable<NSView, CanvasView>.weakToWeakObjects()
    var titlebarAppearance: NSAppearance.Name? { window.flatMap(Self.titlebar(of:))?.appearance?.name }
    /// Keeps the title readable where the title bar can't follow the canvas, by stopping the canvas beneath it.
    private let toolbarCover = PlatformView()
    var toolbarCoverColor: CGColor? { toolbarCover.isHidden ? nil : toolbarCover.layer?.backgroundColor }
    #endif

    init(terminal: TerminalMetalView) {
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
            toolbarCover.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            toolbarCover.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            toolbarCover.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
        ])
        #else
        addSubview(viewport)
        viewport.clipsToBounds = true
        viewport.translatesAutoresizingMaskIntoConstraints = false
        viewport.addSubview(terminal)
        for cover in [insetCover, bottomCover] {
            viewport.addSubview(cover)
            cover.isUserInteractionEnabled = false
            cover.isHidden = true
        }
        for view in [terminal, insetCover, bottomCover] { view.translatesAutoresizingMaskIntoConstraints = false }
        // With the keyboard down, lines run on into the home indicator's strip.
        keyboardLayoutGuide.usesBottomSafeArea = false
        keyboardEdge = viewport.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        pinnedHeight = viewport.heightAnchor.constraint(equalToConstant: 0)
        insetHeight = insetCover.heightAnchor.constraint(equalToConstant: 0)
        gridBottom = bottomCover.topAnchor.constraint(equalTo: viewport.topAnchor)
        gridConstraints = [
            terminal.topAnchor.constraint(equalTo: viewport.topAnchor),
            terminal.heightAnchor.constraint(equalTo: viewport.heightAnchor),
        ]
        // Before UIKit supplies a keyboard frame, its top anchor can be unconstrained.
        // Prefer the canvas's bottom until the keyboard guide determines the viewport height.
        let bottom = viewport.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottom.priority = .defaultLow
        NSLayoutConstraint.activate(gridConstraints + [
            bottom,
            viewport.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            keyboardEdge,
            terminal.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            insetCover.topAnchor.constraint(equalTo: viewport.topAnchor),
            insetCover.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            insetCover.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            insetHeight,
            gridBottom,
            bottomCover.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            bottomCover.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            bottomCover.heightAnchor.constraint(equalTo: viewport.heightAnchor),
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
        updateBar()
    }
    override func viewDidHide() { super.viewDidHide(); onVisibility?(); updateBar() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibility?(); updateBar() }
    override func layout() { super.layout(); updateBar() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBar() }
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

    // Keep the source drawable at its native height while a turn or the keyboard moves the
    // viewport around it. Every row waits where the resized grid will draw it, so its first frame
    // changes nothing. Rows under the grid's top inset or below its last row stay covered, as the
    // resized grid leaves them.
    func beginHold(sourceHeight: CGFloat? = nil) {
        guard holdConstraints.isEmpty else { return }
        terminal.holdsGridGeometry = true
        let top = terminal.topAnchor.constraint(equalTo: viewport.topAnchor)
        holdConstraints = [terminal.heightAnchor.constraint(equalToConstant: sourceHeight ?? terminal.bounds.height), top]
        if let snapshot = terminal.snapshot {
            let offset = terminal.historyOffset
            // A pinned edge doesn't follow the keyboard guide, so it has nothing to wait for.
            held = (top, snapshot.cursorRow - offset, snapshot.size.rows, snapshot.currentShellHistoryCount,
                    offset, guideShowsKeyboard && keyboardEdge.isActive)
        }
        insetHeight.constant = max(0, terminal.cellRect(row: 0, column: 0).minY)
        gridBottom.constant = terminal.cellRect(row: terminal.gridSize?.rows ?? 0, column: 0).minY
        // The lower cover starts where the grid ends now, not where an earlier hold left it.
        UIView.performWithoutAnimation {
            bottomCover.frame = CGRect(x: 0, y: gridBottom.constant, width: viewport.bounds.width, height: viewport.bounds.height)
        }
        for cover in [insetCover, bottomCover] { cover.isHidden = false }
        NSLayoutConstraint.deactivate(gridConstraints)
        NSLayoutConstraint.activate(holdConstraints)
    }

    func endHold() {
        guard !holdConstraints.isEmpty else { return }
        NSLayoutConstraint.deactivate(holdConstraints)
        holdConstraints.removeAll()
        held = nil
        for cover in [insetCover, bottomCover] { cover.isHidden = true }
        NSLayoutConstraint.activate(gridConstraints)
        layoutIfNeeded()
        terminal.holdsGridGeometry = false
    }

    /// Holds the viewport's lower edge at a height in this canvas, where it is now by default, so
    /// the canvas can follow the keyboard's own frame in one motion instead of its layout guide.
    func pinLowerEdge(at y: CGFloat? = nil) {
        pinnedHeight.constant = max(0, (y ?? viewport.frame.maxY) - safeAreaLayoutGuide.layoutFrame.minY)
        keyboardEdge.isActive = false
        pinnedHeight.isActive = true
    }

    func unpinLowerEdge() {
        pinnedHeight.isActive = false
        keyboardEdge.isActive = true
    }

    override func layoutSubviews() {
        let turning = turnMovesViewport ? (frame: viewport.frame, presented: viewport.layer.presentation()) : nil
        super.layoutSubviews()
        if let turning, let presented = turning.presented, viewport.frame != turning.frame,
           UIView.inheritedAnimationDuration == 0 {
            easeViewportIntoTurn(from: turning.frame, presented: presented)
        }
        alignHeldGrid()
        updateBar()
    }

    private var turnMovesViewport: Bool {
        !holdConstraints.isEmpty || viewport.layer.animation(forKey: "turn bounds.size.height") != nil
    }

    // UIKit turns the canvas with additive animations, so a keyboard guide that moves the viewport
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

    // Follows the emulator's resize. A shorter grid scrolls the cursor into view, and a taller one
    // pulls history back above a cursor on the bottom row. A reader keeps the top row while
    // enough rows remain below it. The terminal draws the rows that come into view above or
    // below the held grid. When the key row changes height with a turn, the keyboard guide
    // briefly shows no keyboard outside the turn's animation, so a hold that began over the
    // keyboard waits for the keyboard's own frame.
    private func alignHeldGrid() {
        guard let held, let metrics = terminal.metrics, guideShowsKeyboard || !held.keyboard else { return }
        let rows = metrics.size(in: viewport.bounds.size).rows
        let pulled = rows > held.rows && held.cursor == held.rows - 1 ? min(held.history, rows - held.rows) : 0
        let lowered = if held.offset > 0 { max(0, pulled - held.offset) }
            else if rows < held.rows { min(held.cursor, rows - 1) - held.cursor }
            else { pulled }
        let constant = CGFloat(lowered * metrics.rowHeightPixels) / metrics.scale
        if held.top.constant != constant { held.top.constant = constant }
        let bottom = CGFloat(metrics.y(rows)) / metrics.scale
        if gridBottom.constant != bottom { gridBottom.constant = bottom }
        terminal.heldRowsAround = max(terminal.heldRowsAround, lowered, rows - held.rows - lowered)
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

    /// The area outside the grid follows the program. An overlapping Mac toolbar may need the app's theme.
    private func updateBacking() {
        let background = terminal.color(.background).cgColor
        #if os(macOS)
        layer?.backgroundColor = background
        #else
        backgroundColor = UIColor(cgColor: background)
        for cover in [insetCover, bottomCover] { cover.backgroundColor = backgroundColor }
        #endif
        updateBar()
    }

    /// A bar over the canvas takes the scheme of the background the canvas draws, so its title stays readable.
    private func updateBar() {
        let dark = terminal.color(.background).isDark
        #if os(macOS)
        updateTitlebar(dark: dark)
        #else
        let scheme: ColorScheme? = safeAreaInsets.top > 0 ? (dark ? .dark : .light) : nil
        guard scheme != barScheme else { return }
        barScheme = scheme
        onBarSchemeChange?()
        #endif
    }

    #if os(macOS)
    private func updateTitlebar(dark: Bool) {
        let window = isShellPresented && safeAreaInsets.top > 0 ? self.window : nil
        let next = window.flatMap(Self.titlebar(of:))
        if titlebar !== next {
            if let titlebar { release(titlebar) }
            (titlebar, titlebarFollows) = (next, nil)
        }
        guard let window, dark != window.effectiveAppearance.isDark else {
            if let next { release(next) }
            titlebarFollows = nil
            toolbarCover.isHidden = true
            return
        }
        if titlebarFollows?.dark != dark { titlebarFollows = (dark, true) }
        if let next, titlebarFollows?.follows == true, canvasSpan(under: next) != nil {
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if next.appearance?.name != name { next.appearance = NSAppearance(named: name) }
            Self.titlebarOwners.setObject(self, forKey: next)
            toolbarCover.isHidden = true
            checkTitlebar()
        } else {
            if let next { release(next) }
            // The theme's background where it suits the window's title, or else the window's.
            let theme = terminal.resolvedTheme.palette.background
            var cover = theme.cgColor
            if theme.isDark == dark {
                window.effectiveAppearance.performAsCurrentDrawingAppearance { cover = NSColor.windowBackgroundColor.cgColor }
            }
            toolbarCover.layer?.backgroundColor = cover
            toolbarCover.isHidden = false
        }
    }

    /// Checks a moment later, once AppKit has settled the title bar, that the canvas's appearance landed only over
    /// the canvas. A split view's visible toolbar background keeps its items on the window's appearance, and some
    /// split views let a sidebar's buttons follow the bar, so then the canvas stops beneath the bar instead.
    private func checkTitlebar() {
        guard titlebarCheck == nil else { return }
        titlebarCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            titlebarCheck = nil
            guard let titlebar, let window, Self.titlebarOwners.object(forKey: titlebar) === self,
                  let asked = titlebarFollows, let span = canvasSpan(under: titlebar) else { return }
            titlebar.layoutSubtreeIfNeeded()
            guard !Self.follows(titlebar, of: window, over: span, isDark: asked.dark) else { return }
            titlebarFollows?.follows = false
            updateBar()
        }
    }

    private func release(_ titlebar: NSView) {
        guard Self.titlebarOwners.object(forKey: titlebar) === self else { return }
        if titlebar.appearance != nil { titlebar.appearance = nil }
        Self.titlebarOwners.removeObject(forKey: titlebar)
    }

    /// The window span where the canvas shows through the title bar, beside any sidebar floating over the canvas,
    /// or nil when the canvas doesn't span the bar, so flipping it would also flip chrome over other content.
    private func canvasSpan(under titlebar: NSView) -> ClosedRange<CGFloat>? {
        let canvas = convert(bounds, to: nil), bar = titlebar.convert(titlebar.bounds, to: nil)
        guard canvas.minX <= bar.minX + 0.5, canvas.maxX >= bar.maxX - 0.5 else { return nil }
        let start = canvas.minX + safeAreaInsets.left
        return start...max(start, canvas.maxX - safeAreaInsets.right)
    }

    /// Whether everything in the bar over the canvas took its appearance, while the window buttons and toolbar items
    /// beside it, over a sidebar, kept the window's.
    private static func follows(_ titlebar: NSView, of window: NSWindow, over span: ClosedRange<CGFloat>, isDark dark: Bool) -> Bool {
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let beside = buttons.compactMap { window.standardWindowButton($0) as NSView? } + (window.toolbar?.items.compactMap(\.view) ?? [])
        return everything(in: titlebar, over: span, isDark: dark) && beside.allSatisfy { view in
            let frame = view.convert(view.bounds, to: nil)
            let over = frame.maxX > span.lowerBound && frame.minX < span.upperBound
            return over || view.isHiddenOrHasHiddenAncestor || view.effectiveAppearance.isDark == window.effectiveAppearance.isDark
        }
    }

    private static func everything(in view: NSView, over span: ClosedRange<CGFloat>, isDark dark: Bool) -> Bool {
        guard !view.isHidden else { return true }
        let frame = view.convert(view.bounds, to: nil)
        if span.contains(frame.minX), span.contains(frame.maxX), view.effectiveAppearance.isDark != dark { return false }
        return view.subviews.allSatisfy { everything(in: $0, over: span, isDark: dark) }
    }

    /// The window frame's child that holds the title, window buttons and toolbar: the one holding the close button,
    /// or else the one above the content layout rect.
    private static func titlebar(of window: NSWindow) -> NSView? {
        guard let frame = window.contentView?.superview else { return nil }
        var view = window.standardWindowButton(.closeButton) as NSView?
        while let child = view, let parent = child.superview, parent !== frame { view = parent }
        if let view, view.superview === frame { return view }
        let top = window.contentLayoutRect.maxY
        return frame.subviews.last { $0 !== window.contentView && $0.frame.minY >= top }
    }
    #endif

}

#if os(iOS)
extension TerminalMetalView {
    package var canvasGeometryInWindow: (frame: CGRect, safeArea: CGRect, firstCell: CGRect)? {
        guard let canvas = superview?.superview as? CanvasView, let window else { return nil }
        return (canvas.convert(canvas.bounds, to: window),
                canvas.convert(canvas.safeAreaLayoutGuide.layoutFrame, to: window),
                convert(cellRect(row: 0, column: 0), to: window))
    }
}
#endif
