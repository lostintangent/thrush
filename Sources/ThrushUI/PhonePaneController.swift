#if os(iOS)
import UIKit

/// UIKit tells view controllers about a turn before it relays the new bounds to their views.
@MainActor final class PhonePaneController: UIViewController {
    private let pane: TerminalPaneContainer
    private weak var rotation: (any UIViewControllerTransitionCoordinator)?
    private var coordinatorFinished = false
    private var keyboardWasVisible = false
    private var keyboardEnd: CGRect?
    private var lastBounds: CGSize?
    private var settleDuration: TimeInterval = 0
    private var settleTask: Task<Void, Never>?

    init(_ pane: TerminalPaneContainer) {
        self.pane = pane
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = pane }

    override func viewDidLoad() {
        super.viewDidLoad()
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: name, object: nil)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        if !coordinator.targetTransform.isIdentity, pane.terminal.gridSize != nil {
            settleTask?.cancel()
            rotation = coordinator
            coordinatorFinished = false
            keyboardWasVisible = pane.keyboardLayoutGuide.layoutFrame.height > pane.safeAreaInsets.bottom + 1
            keyboardEnd = nil
            lastBounds = nil
            settleDuration = coordinator.transitionDuration
            pane.beginRotation()
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
        guard pane.terminal.holdsGridGeometry, let window = pane.window,
              let screen = window.windowScene?.screen,
              (note.object as? UIScreen).map({ $0 === screen }) != false,
              let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        keyboardEnd = frame.cgRectValue
        checkGeometry()
    }

    private func checkGeometry() {
        guard pane.terminal.holdsGridGeometry else { return }
        // The keyboard may publish its destination before UIKit completes the rotation.
        if keyboardWasVisible && keyboardMatchesGuide() {
            finishRotation()
            return
        }
        guard coordinatorFinished else { return }
        if !keyboardWasVisible {
            finishRotation()
            return
        }
        // The keyboard can deliver its layout after the orientation coordinator finishes.
        // When UIKit sends no keyboard frame notification, wait for one system animation
        // interval without another change to the usable bounds.
        let bounds = pane.viewportSize
        guard bounds != lastBounds else { return }
        lastBounds = bounds
        settleTask?.cancel()
        let interval = max(settleDuration, UIView.inheritedAnimationDuration)
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            self?.finishRotation()
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
        return !expected.isEmpty && abs(guide.minX - expected.minX) <= 1 && abs(guide.maxX - expected.maxX) <= 1
            && abs(guide.minY - expected.minY) <= 1 && abs(guide.maxY - expected.maxY) <= 1
    }

    func finishRotation() {
        settleTask?.cancel()
        settleTask = nil
        rotation = nil
        coordinatorFinished = false
        pane.endRotation()
    }
}
#endif
