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
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFinished(_:)),
                                                name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
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
            pane.terminal.holdsGridGeometry = true
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

    @objc private func keyboardFinished(_ note: Notification) {
        guard pane.terminal.holdsGridGeometry, let window = pane.window,
              let screen = window.windowScene?.screen,
              (note.object as? UIScreen).map({ $0 === screen }) != false,
              let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardEnd = end
        checkGeometry()
    }

    private func checkGeometry() {
        guard pane.terminal.holdsGridGeometry, coordinatorFinished else { return }
        if !keyboardWasVisible || keyboardMatchesGuide() {
            finishRotation()
            return
        }
        // The keyboard can deliver its layout after the orientation coordinator finishes.
        // When UIKit sends no keyboard frame notification, wait for one system animation
        // interval without another change to the usable bounds.
        let bounds = pane.terminal.bounds.size
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
        guard let keyboardEnd, let screen = pane.window?.windowScene?.screen else { return false }
        let keyboard = pane.convert(keyboardEnd, from: screen.coordinateSpace)
        let keyboardTop = min(pane.bounds.maxY - pane.safeAreaInsets.bottom, keyboard.minY)
        return abs(keyboardTop - pane.keyboardLayoutGuide.layoutFrame.minY) <= 1
    }

    func finishRotation() {
        settleTask?.cancel()
        settleTask = nil
        rotation = nil
        pane.terminal.holdsGridGeometry = false
    }
}
#endif
