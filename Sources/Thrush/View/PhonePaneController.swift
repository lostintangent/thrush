#if os(iOS)
import UIKit

/// UIKit tells view controllers about a turn before it relays the new bounds to their views.
@MainActor final class PhonePaneController: UIViewController {
    private let pane: TerminalPaneContainer
    private weak var rotation: (any UIViewControllerTransitionCoordinator)?
    private var coordinatorFinished = false
    private var releasing = false
    private var keyboardWasVisible = false
    private var keyboardEnd: CGRect?
    private var sourceWidth: CGFloat?
    private var lastBounds: CGSize?
    private var settleDuration: TimeInterval = 0
    private var settleTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var keyboardMoving = false
    private var keyboardTarget: CGRect?
    private var keyboardTask: Task<Void, Never>?

    init(_ pane: TerminalPaneContainer) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = pane }

    override func viewDidLoad() {
        super.viewDidLoad()
        pane.terminal.beforeViewportResize = { [weak self] source in self?.keyboardLayoutBegan(source: source) }
        pane.terminal.beforeKeyboardMove = { [weak self] in self?.keyboardMoveBegan() }
        pane.terminal.onHeldGridReady = { [weak self] in
            // A frame requested before another turn began must not end the new hold.
            if self?.releaseTask != nil { self?.releaseHold() }
        }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: name, object: nil)
        }
    }

    private func keyboardLayoutBegan(source: CGSize) {
        // The keyboard can install its destination height while the window is still in
        // the source orientation, before UIKit calls viewWillTransition on the pane.
        guard !releasing, !pane.terminal.holdsGridGeometry, pane.terminal.phoneInput.isFirstResponder,
              source.height != pane.terminal.bounds.height, keyboardEnd != nil, pane.guideShowsKeyboard,
              !keyboardMatchesGuide() else { return }
        coordinatorFinished = true
        keyboardWasVisible = true
        sourceWidth = nil
        lastBounds = nil
        settleDuration = max(UIView.inheritedAnimationDuration, CATransaction.animationDuration())
        pane.beginHold(sourceHeight: source.height)
        checkGeometry()
    }

    // UIKit moves the keyboard guide in steps around the keyboard's own animation. On the way up
    // it first leaves out the key row, and on the way down it waits at the key row's height. So
    // the pane pins its lower edge and moves it once, inside the keyboard's animation, to where
    // the keyboard will stop, holding the grid until the keyboard is there.
    private func keyboardMoveBegan() {
        guard pane.window != nil, pane.terminal.gridSize != nil, !releasing else { return }
        if !keyboardMoving {
            guard !pane.terminal.holdsGridGeometry else { return }
            keyboardMoving = true
            pane.pinLowerEdge()
            pane.beginHold()
        }
        finishKeyboardMove(after: Self.keyboardWait)
    }

    private func moveWithKeyboard(to end: CGRect, duration: TimeInterval) {
        guard let window = pane.window, let screen = window.windowScene?.screen else { return }
        let inWindow = window.convert(end, from: screen.coordinateSpace)
        // UIKit's guide already follows a floating keyboard, which never moves the edge.
        guard abs(inWindow.width - window.bounds.width) <= 1 else { return finishKeyboardMove() }
        keyboardTarget = end
        let bottom = pane.safeAreaLayoutGuide.layoutFrame.maxY
        let covered = pane.bounds.intersection(pane.convert(inWindow, from: window))
        pane.pinLowerEdge(at: covered.isEmpty ? bottom : min(covered.minY, bottom))
        pane.layoutIfNeeded()
        finishKeyboardMove(after: duration + Self.keyboardWait)
    }

    private func finishKeyboardMove(after interval: TimeInterval) {
        keyboardTask?.cancel()
        keyboardTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            self?.finishKeyboardMove()
        }
    }

    private func finishKeyboardMove() {
        guard keyboardMoving else { return }
        stopFollowingKeyboard()
        finishHold()
    }

    private func stopFollowingKeyboard() {
        keyboardTask?.cancel()
        keyboardTask = nil
        keyboardTarget = nil
        guard keyboardMoving else { return }
        keyboardMoving = false
        pane.unpinLowerEdge()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        if !coordinator.targetTransform.isIdentity, pane.terminal.gridSize != nil {
            // The turn takes over a keyboard move's hold.
            stopFollowingKeyboard()
            settleTask?.cancel()
            releaseTask?.cancel()
            releaseTask = nil
            rotation = coordinator
            coordinatorFinished = false
            keyboardWasVisible = (pane.terminal.holdsGridGeometry && keyboardWasVisible) || pane.guideShowsKeyboard
            keyboardEnd = nil
            sourceWidth = pane.bounds.width
            lastBounds = nil
            settleDuration = coordinator.transitionDuration
            pane.beginHold()
            let registered = coordinator.animate(alongsideTransition: nil) { [weak self, weak coordinator] _ in
                guard let self, let coordinator, rotation === coordinator else { return }
                coordinatorFinished = true
                checkGeometry()
            }
            if !registered {
                coordinatorFinished = true
                checkGeometry()
            }
        }
        super.viewWillTransition(to: size, with: coordinator)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        checkGeometry()
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let window = pane.window,
              let screen = window.windowScene?.screen,
              (note.object as? UIScreen).map({ $0 === screen }) != false,
              let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        keyboardEnd = frame.cgRectValue
        if keyboardMoving {
            if note.name == UIResponder.keyboardWillChangeFrameNotification {
                let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
                moveWithKeyboard(to: frame.cgRectValue, duration: duration ?? 0)
            } else if keyboardTarget == frame.cgRectValue {
                finishKeyboardMove()
            }
            return
        }
        checkGeometry()
    }

    private func checkGeometry() {
        guard pane.terminal.holdsGridGeometry, !keyboardMoving, releaseTask == nil else { return }
        // The keyboard may reach its destination before UIKit completes the rotation.
        if keyboardWasVisible && (keyboardMatchesGuide() || guideFollowsTurn()) {
            finishHold()
            return
        }
        guard coordinatorFinished else { return }
        if !keyboardWasVisible {
            finishHold()
            return
        }
        // The keyboard can deliver its layout after the orientation coordinator finishes.
        // When UIKit sends no keyboard frame notification, wait for one system animation
        // interval without another change to the usable bounds. A guide that still has the
        // source orientation's width keeps that orientation's keyboard height, so it only
        // settles after a much longer wait.
        let bounds = pane.viewportSize
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        settleTask?.cancel()
        let interval = guideSpansPane ? max(settleDuration, UIView.inheritedAnimationDuration) : Self.staleGuideWait
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            self?.finishHold()
        }
    }

    private func keyboardMatchesGuide() -> Bool {
        guard let keyboardEnd, let window = pane.window, let screen = window.windowScene?.screen else { return false }
        // UIKit publishes partial keyboard frames while rotating the two keyboard windows.
        // Match all four edges of the docked keyboard, clipped to this pane's coordinates.
        let inWindow = window.convert(keyboardEnd, from: screen.coordinateSpace)
        guard abs(inWindow.width - window.bounds.width) <= 1 else { return false }
        let expected = pane.bounds.intersection(pane.convert(inWindow, from: window))
        let guide = pane.keyboardLayoutGuide.layoutFrame
        if expected.isEmpty {
            return inWindow.minY >= window.bounds.maxY - 1 && abs(guide.minY - pane.safeAreaLayoutGuide.layoutFrame.maxY) <= 1
        }
        return abs(guide.minX - expected.minX) <= 1 && abs(guide.maxX - expected.maxX) <= 1
            && abs(guide.minY - expected.minY) <= 1 && abs(guide.maxY - expected.maxY) <= 1
    }

    /// After the window turns, UIKit moves the keyboard guide from the source orientation's
    /// keyboard to the destination's. The keyboard can confirm that frame only after the
    /// rotation ends, and in Dark it first reports a keyboard without keycaps. When the key
    /// row changes height with the turn, the guide first passes through the bare safe area.
    private func guideFollowsTurn() -> Bool {
        guard let sourceWidth else { return false }
        return abs(pane.bounds.width - sourceWidth) > 1 && guideSpansPane && pane.guideShowsKeyboard
    }

    private var guideSpansPane: Bool { abs(pane.keyboardLayoutGuide.layoutFrame.width - pane.bounds.width) <= 1 }

    func finishHold() {
        settleTask?.cancel()
        settleTask = nil
        rotation = nil
        coordinatorFinished = false
        sourceWidth = nil
        // Keep the anchored source frame until the terminal delivers a frame at the
        // destination size, then commit the new layout together with that frame.
        pane.layoutIfNeeded()
        guard pane.terminal.publishHeldGrid(for: pane.viewportSize) else { return releaseHold() }
        releaseTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.frameWait) } catch { return }
            self?.releaseHold()
        }
    }

    /// A connection that is replaying or reconnecting may not answer a resize with a frame, and a
    /// loaded system can take a few hundred milliseconds to draw one.
    static let frameWait = Duration.seconds(1)
    /// A loaded system can keep the keyboard in the source orientation for well over a second.
    static let staleGuideWait: TimeInterval = 3
    /// The keyboard can take a while to answer a first responder change on a loaded system.
    static let keyboardWait: TimeInterval = 1

    /// Ends any hold now, as when SwiftUI removes the pane.
    func releaseHold() {
        stopFollowingKeyboard()
        settleTask?.cancel()
        settleTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        rotation = nil
        coordinatorFinished = false
        sourceWidth = nil
        releasing = true
        pane.endHold()
        releasing = false
    }
}
#endif
