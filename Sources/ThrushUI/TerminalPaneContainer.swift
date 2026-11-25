import SwiftUI
import Thrush

enum PaneNotice: Equatable {
    case connecting(retainingTranscript: Bool)
    case reconnecting
    case replacement(discardedInput: Bool)
    case displaced, exited, closed

    var title: String {
        switch self {
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .replacement: "Previous shell ended"
        case .displaced: "Open in another window"
        case .exited, .closed: "Ended"
        }
    }

    var detail: String? {
        switch self {
        case .reconnecting: "Typing waits for this shell to resume."
        case .replacement(let discarded): discarded ? "New shell ready. Held input was discarded." : "New shell ready."
        default: nil
        }
    }

    var action: String? {
        switch self {
        case .displaced: "Use Here"
        case .exited: "New Shell"
        default: nil
        }
    }

    var actionLabel: String? { self == .displaced ? "Use shell in this window" : action }
    var actionHint: String { self == .exited ? "Starts a new shell." : "" }

    var isCentered: Bool { self == .connecting(retainingTranscript: false) }

    var showsProgress: Bool {
        switch self {
        case .connecting, .reconnecting: true
        default: false
        }
    }
}

private extension Terminal.RGB {
    var paneColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    var paneCGColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

@MainActor private struct PaneMessage: View {
    let notice: PaneNotice
    let theme: TerminalTheme
    let actionEnabled: Bool
    let activate: () -> Void
    let readingChanged: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @AccessibilityFocusState private var readingStatus: Bool
    #if os(iOS)
    @ScaledMetric(relativeTo: .body) private var titleSize = 17.0
    @ScaledMetric(relativeTo: .subheadline) private var detailSize = 15.0
    private let inset: CGFloat = 16
    #else
    private let titleSize: CGFloat = 13
    private let detailSize: CGFloat = 12
    private let inset: CGFloat = 12
    #endif

    private var detailColor: Color {
        if theme == .slateDark { return Terminal.RGB(red: 0x86, green: 0x97, blue: 0xA4).paneColor }
        if theme == .slateLight { return Terminal.RGB(red: 0x58, green: 0x6D, blue: 0x7B).paneColor }
        return theme.palette.foreground.paneColor
    }

    var body: some View {
        Group {
            if notice.isCentered {
                HStack(spacing: 8) { indicator; heading }
                    .accessibilityElement(children: .combine)
                    .accessibilityFocused($readingStatus)
                    .accessibilityIdentifier("terminal.status")
            } else {
                ViewThatFits(in: .vertical) {
                    controls.fixedSize(horizontal: false, vertical: true)
                    ScrollView(.vertical) { controls }
                }
                .padding(.top, 1 / max(1, displayScale))
            }
        }
        .foregroundStyle(theme.palette.foreground.paneColor)
        .onChange(of: readingStatus) { _, focused in readingChanged(focused) }
    }

    private var heading: some View {
        Text(notice.title)
            .font(.system(size: titleSize, weight: .semibold))
            .accessibilityIdentifier("terminal.status.title")
    }

    private var indicator: some View {
        Group {
            if reduceMotion {
                Image(systemName: "circle.dotted")
                    .font(.system(size: titleSize))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .foregroundStyle(detailColor)
        .accessibilityHidden(true)
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 8) {
            if notice.showsProgress { indicator }
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 2) {
                    heading
                    if let detail = notice.detail {
                        Text(detail).font(.system(size: detailSize)).foregroundStyle(detailColor)
                            .accessibilityIdentifier("terminal.status.detail")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityFocused($readingStatus)
                .accessibilityIdentifier("terminal.status")

                if let caption = notice.action {
                    PaneActionButton(caption: caption, label: notice.actionLabel ?? caption, hint: notice.actionHint,
                                     enabled: actionEnabled, theme: theme, activate: activate)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.vertical, 8)
    }
}

@MainActor private struct PaneActionButton {
    let caption: String
    let label: String
    let hint: String
    let enabled: Bool
    let theme: TerminalTheme
    let activate: () -> Void

    final class Coordinator: NSObject {
        var action: (() -> Void)?
        @objc func press() { action?() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
}

#if os(macOS)
extension PaneActionButton: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: caption, target: context.coordinator, action: #selector(Coordinator.press))
        button.bezelStyle = .push
        button.controlSize = .regular
        button.setAccessibilityIdentifier("terminal.status.action")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = activate
        button.title = caption
        button.isEnabled = enabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityUserInputLabels([caption])
        button.setAccessibilityHelp(hint)
        // AppKit exposes the button cell to assistive clients. Keep its spoken
        // title separate from the visible caption that Voice Control also accepts.
        if let action = NSAccessibility.unignoredDescendant(of: button) as? NSAccessibilityProtocol {
            action.setAccessibilityTitle(label)
            action.setAccessibilityLabel(label)
            action.setAccessibilityUserInputLabels([caption])
            action.setAccessibilityHelp(hint)
        }
    }
}
#else
extension PaneActionButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        let coordinator = context.coordinator
        button.addAction(UIAction { _ in coordinator.press() }, for: .touchUpInside)
        button.accessibilityIdentifier = "terminal.status.action"
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = activate
        var style = UIButton.Configuration.filled()
        style.title = caption
        let traits = button.traitCollection
        style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold),
                                                                               compatibleWith: traits)
            return result
        }
        style.cornerStyle = .capsule
        style.contentInsets = .init(top: 10, leading: 10, bottom: 10, trailing: 10)
        style.background.backgroundInsets = .init(top: 6, leading: 0, bottom: 6, trailing: 0)
        style.baseForegroundColor = UIColor(cgColor: theme.palette.foreground.paneCGColor)
        style.baseBackgroundColor = UIColor(cgColor: theme.separator.paneCGColor)
        button.configuration = style
        button.isEnabled = enabled
        button.accessibilityLabel = label
        button.accessibilityUserInputLabels = [caption]
        button.accessibilityHint = hint
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        let size = uiView.intrinsicContentSize
        return CGSize(width: max(44, size.width), height: max(44, size.height))
    }
}
#endif

#if os(macOS)
typealias PaneNativeView = NSView
private typealias NoticeHost = NSHostingView<PaneMessage>
#else
typealias PaneNativeView = UIView
private typealias NoticeHost = UIView & UIContentView
#endif

/// The terminal always measures the full usable grid. A temporary notice clips the native
/// viewport and lifts it by whole cells only when needed to keep the reading position visible.
@MainActor final class TerminalPaneContainer: PaneNativeView {
    let terminal: TerminalView
    var onVisibility: (() -> Void)?
    #if os(macOS)
    private weak var closingWindow: NSWindow?
    #else
    private var sceneState: UIScene.ActivationState?
    private var visibilityObservations: [NSKeyValueObservation] = []
    #endif
    var onAction: (() -> Void)?
    var onNoticeReadChange: ((Bool) -> Void)?

    private let viewport = PaneNativeView()
    private let rowCover = PaneNativeView()
    private let backing = PaneNativeView()
    private let divider = PaneNativeView()
    private var noticeView: NoticeHost?
    private(set) var current: PaneNotice?
    var mountedNoticeView: PaneNativeView? { noticeView }
    var mountedNoticeBacking: PaneNativeView? { backing.isHidden ? nil : backing }
    private var lastTheme: TerminalTheme?
    private var gridTop: NSLayoutConstraint!
    private var coveredHeight: NSLayoutConstraint!
    private var hiddenBackingTop: NSLayoutConstraint!
    private var dividerHeight: NSLayoutConstraint!
    private var availableHeight: NSLayoutDimension!
    private var lowerEdge: NSLayoutYAxisAnchor!
    private var noticeConstraints: [NSLayoutConstraint] = []
    private var activated = false
    private var accessibilityFocus = false
    private var speaking: String?
    private var wasReading = false

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        viewport.wantsLayer = true
        viewport.layer?.masksToBounds = true
        rowCover.wantsLayer = true
        backing.wantsLayer = true
        divider.wantsLayer = true
        let guide = NSLayoutGuide()
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: leadingAnchor), guide.trailingAnchor.constraint(equalTo: trailingAnchor),
            guide.topAnchor.constraint(equalTo: topAnchor), guide.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #else
        viewport.clipsToBounds = true
        backing.isUserInteractionEnabled = false
        divider.isUserInteractionEnabled = false
        let guide = UILayoutGuide()
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            guide.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            guide.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            guide.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        #endif
        availableHeight = guide.heightAnchor
        lowerEdge = guide.bottomAnchor
        addSubview(viewport)
        addSubview(rowCover)
        addSubview(backing)
        backing.addSubview(divider)
        viewport.addSubview(terminal)
        for view in [viewport, rowCover, backing, divider, terminal] { view.translatesAutoresizingMaskIntoConstraints = false }
        backing.isHidden = true
        gridTop = terminal.topAnchor.constraint(equalTo: guide.topAnchor)
        coveredHeight = rowCover.heightAnchor.constraint(equalToConstant: 0)
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: 1)
        hiddenBackingTop = backing.topAnchor.constraint(equalTo: lowerEdge)
        NSLayoutConstraint.activate([
            viewport.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            viewport.topAnchor.constraint(equalTo: guide.topAnchor),
            viewport.bottomAnchor.constraint(equalTo: lowerEdge),
            rowCover.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            rowCover.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            rowCover.bottomAnchor.constraint(equalTo: lowerEdge),
            coveredHeight,
            terminal.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
            terminal.heightAnchor.constraint(equalTo: guide.heightAnchor),
            gridTop,
            backing.leadingAnchor.constraint(equalTo: leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: bottomAnchor),
            hiddenBackingTop,
            divider.topAnchor.constraint(equalTo: backing.topAnchor),
            divider.leadingAnchor.constraint(equalTo: backing.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: backing.trailingAnchor),
            dividerHeight,
        ])
        terminal.onViewportInteractionChange = { [weak self] in self?.keepReadingPositionVisible() }

        let center = NotificationCenter.default
        #if os(macOS)
        let notifications = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                             NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                             NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                             NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                             NSWindow.didBecomeKeyNotification]
        #else
        let notifications = [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                             UIScene.willEnterForegroundNotification, UIScene.didEnterBackgroundNotification,
                             UIScene.didDisconnectNotification]
        center.addObserver(self, selector: #selector(announcementFinished(_:)),
                           name: UIAccessibility.announcementDidFinishNotification, object: nil)
        center.addObserver(self, selector: #selector(voiceOverChanged),
                           name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        #endif
        for name in notifications {
            center.addObserver(self, selector: #selector(lifecycleChanged(_:)), name: name, object: nil)
        }
        updateBacking(terminal.resolvedTheme)
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

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        closingWindow = nil
        onVisibility?()
    }
    override func viewDidHide() { super.viewDidHide(); onVisibility?() }
    override func viewDidUnhide() { super.viewDidUnhide(); onVisibility?() }
    override func layout() { super.layout(); keepReadingPositionVisible() }
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

    override func layoutSubviews() { super.layoutSubviews(); keepReadingPositionVisible() }

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

    private func updateBacking(_ theme: TerminalTheme) {
        #if os(macOS)
        rowCover.layer?.backgroundColor = theme.palette.background.paneCGColor
        layer?.backgroundColor = theme.palette.background.paneCGColor
        backing.layer?.backgroundColor = theme.hostBacking.paneCGColor
        divider.layer?.backgroundColor = theme.separator.paneCGColor
        #else
        rowCover.backgroundColor = UIColor(cgColor: theme.palette.background.paneCGColor)
        backgroundColor = UIColor(cgColor: theme.palette.background.paneCGColor)
        backing.backgroundColor = UIColor(cgColor: theme.hostBacking.paneCGColor)
        divider.backgroundColor = UIColor(cgColor: theme.separator.paneCGColor)
        #endif
    }

    func show(_ next: PaneNotice?) {
        let theme = terminal.resolvedTheme
        guard current != next || theme != lastTheme else { return }
        let changed = current != next
        current = next
        lastTheme = theme
        if changed {
            activated = false
            accessibilityFocus = false
            speaking = nil
        }
        updateBacking(theme)
        refreshMessage()
        if changed, let next { announce(next) }
        updateReading()
    }

    private func refreshMessage() {
        guard let notice = current, let theme = lastTheme else {
            guard let outgoing = noticeView else { return }
            resetClip()
            fade(outgoing, to: 0) { [weak self, weak outgoing] in
                guard let self, current == nil, noticeView === outgoing else { return }
                NSLayoutConstraint.deactivate(noticeConstraints)
                noticeConstraints.removeAll()
                hiddenBackingTop.isActive = true
                noticeView?.removeFromSuperview()
                noticeView = nil
                backing.isHidden = true
            }
            return
        }
        let content = PaneMessage(notice: notice, theme: theme, actionEnabled: !activated) { [weak self] in
            guard let self, current == notice, !activated, let onAction else { return }
            activated = true
            refreshMessage()
            onAction()
        } readingChanged: { [weak self] value in
            guard let self, current == notice else { return }
            accessibilityFocus = value
            updateReading()
        }

        let native: NoticeHost
        if let existing = noticeView {
            native = existing
            #if os(macOS)
            existing.rootView = content
            #else
            existing.configuration = UIHostingConfiguration { content }.margins(.all, 0)
            #endif
        } else {
            #if os(macOS)
            native = NSHostingView(rootView: content)
            native.sizingOptions = [.intrinsicContentSize]
            #else
            native = UIHostingConfiguration { content }.margins(.all, 0).makeContentView()
            #endif
            native.translatesAutoresizingMaskIntoConstraints = false
            addSubview(native)
            noticeView = native
            #if os(macOS)
            native.alphaValue = 0
            backing.alphaValue = 0
            #else
            native.alpha = 0
            backing.alpha = 0
            #endif
        }
        NSLayoutConstraint.deactivate(noticeConstraints)
        hiddenBackingTop.isActive = notice.isCentered
        if notice.isCentered {
            backing.isHidden = true
            resetClip()
            noticeConstraints = [
                native.centerXAnchor.constraint(equalTo: viewport.centerXAnchor),
                native.centerYAnchor.constraint(equalTo: viewport.centerYAnchor),
                native.widthAnchor.constraint(lessThanOrEqualTo: viewport.widthAnchor),
            ]
        } else {
            backing.isHidden = false
            noticeConstraints = [
                native.leadingAnchor.constraint(equalTo: viewport.leadingAnchor),
                native.trailingAnchor.constraint(equalTo: viewport.trailingAnchor),
                native.bottomAnchor.constraint(equalTo: lowerEdge),
                native.heightAnchor.constraint(lessThanOrEqualTo: availableHeight, multiplier: 0.75),
                backing.topAnchor.constraint(equalTo: native.topAnchor),
            ]
        }
        NSLayoutConstraint.activate(noticeConstraints)
        keepReadingPositionVisible()
        fade(native, to: 1)
    }

    private func resetClip() {
        gridTop.constant = 0
        coveredHeight.constant = 0
        if terminal.noticeBottomInset != 0 { terminal.noticeBottomInset = 0 }
    }

    private func keepReadingPositionVisible() {
        guard let current, !current.isCentered, let noticeView else { return }
        #if os(macOS)
        let scale = window?.backingScaleFactor ?? 1
        #else
        let scale = traitCollection.displayScale
        #endif
        let hairline = 1 / max(1, scale)
        if dividerHeight.constant != hairline { dividerHeight.constant = hairline }
        let available = max(0, terminal.bounds.height - noticeView.bounds.height)
        let cell = terminal.cellRect(row: 0, column: 0)
        guard cell.height > 0 else { return }
        let target: CGFloat
        if let selection = terminal.selection {
            target = terminal.cellRect(row: selection.headRow, column: selection.headColumn).maxY
        } else if terminal.historyOffset == 0 {
            target = terminal.cursorRect.maxY
        } else {
            target = 0
        }
        let lift = min(ceil(noticeView.bounds.height / cell.height),
                       max(0, ceil((target + cell.minY - available) / cell.height))) * cell.height
        if gridTop.constant != -lift { gridTop.constant = -lift }
        // Keep the last glyph row whole even at large text sizes or fractional backing scales.
        let rows = max(0, floor((available + lift - cell.minY) / cell.height))
        let edge = max(0, cell.minY + rows * cell.height - lift)
        let clipped = max(0, terminal.bounds.height - edge)
        // Keep the Metal layer's parent at its original size. Resizing a layer-backed AppKit
        // clipping view can translate the drawable in WindowServer even with stable NSView bounds.
        if coveredHeight.constant != clipped { coveredHeight.constant = clipped }
        let obscured = max(0, clipped - lift)
        if terminal.noticeBottomInset != obscured { terminal.noticeBottomInset = obscured }
    }

    private func fade(_ view: PaneNativeView, to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        #if os(macOS)
        guard isDrawingVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = alpha
            backing.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            view.animator().alphaValue = alpha
            backing.animator().alphaValue = alpha
        } completionHandler: { Task { @MainActor in completion?() } }
        #else
        guard isDrawingVisible, !UIAccessibility.isReduceMotionEnabled else {
            view.alpha = alpha
            backing.alpha = alpha
            completion?()
            return
        }
        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            view.alpha = alpha
            self.backing.alpha = alpha
        } completion: { _ in completion?() }
        #endif
    }

    private func announce(_ notice: PaneNotice) {
        guard window != nil else { return }
        let value = [notice.title, notice.detail].compactMap { $0 }.joined(separator: ". ")
        #if os(macOS)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: value, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        #else
        guard UIAccessibility.isVoiceOverRunning else { return }
        speaking = value
        UIAccessibility.post(notification: .announcement, argument: value)
        #endif
    }

    #if os(iOS)
    @objc private func announcementFinished(_ notification: Notification) {
        if let speaking, notification.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String == speaking {
            self.speaking = nil
            updateReading()
        }
    }

    @objc private func voiceOverChanged() {
        if !UIAccessibility.isVoiceOverRunning { speaking = nil; accessibilityFocus = false; updateReading() }
    }
    #endif

    private func updateReading() {
        let reading = accessibilityFocus || speaking != nil
        guard wasReading != reading else { return }
        wasReading = reading
        onNoticeReadChange?(reading)
    }
}


extension TerminalView {
    /// The packaged host verifies ownership actions through the same native control a person uses.
    package func activatePaneAction(named accessibilityLabel: String) -> Bool {
        var ancestor = superview
        while let item = ancestor {
            if let container = item as? TerminalPaneContainer {
                return container.activateAction(named: accessibilityLabel)
            }
            ancestor = item.superview
        }
        return false
    }
}

private extension TerminalPaneContainer {
    func activateAction(named label: String) -> Bool {
        guard !activated, current?.actionLabel == label, let noticeView else { return false }
        var pending: [PaneNativeView] = [noticeView]
        while let view = pending.popLast() {
            #if os(macOS)
            if let button = view as? NSButton, button.isEnabled, button.accessibilityLabel() == label {
                button.performClick(nil)
                return activated || current?.actionLabel != label
            }
            #else
            if let button = view as? UIButton, button.isEnabled, button.accessibilityLabel == label {
                button.sendActions(for: .touchUpInside)
                return activated || current?.actionLabel != label
            }
            #endif
            pending.append(contentsOf: view.subviews)
        }
        return false
    }
}
