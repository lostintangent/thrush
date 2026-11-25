#if os(iOS)
import Thrush
import ThrushUI
import UIKit

@main
final class ThrushPhone: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Terminal", sessionRole: session.role)
        configuration.delegateClass = PhoneScene.self
        return configuration
    }
}

@objc(ThrushPhoneScene) private final class PhoneScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let host = PhoneHost()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        switch host.session.options.customTheme ? .dark : host.session.options.appearance {
        case .dark: window.overrideUserInterfaceStyle = .dark
        case .light: window.overrideUserInterfaceStyle = .light
        case .system: break
        }
        window.rootViewController = host
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        PhoneCapture.orient(scene)
        host.session.setActive(true)
        host.focusIfRequested()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        host.session.setActive(false)
    }
}

private extension UIColor {
    convenience init(terminal rgb: Terminal.RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                  blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

private final class PhoneHost: UIViewController {
    let session = DemoSession(options: DemoOptions())
    private var focusRequested = false
    private var captureLayout: (() -> Void)?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if session.view.theme != nil { return .lightContent }
        return traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grid = session.view
        view.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            grid.topAnchor.constraint(equalTo: safe.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        session.onThemeChange = { [weak self] in self?.applyChrome($0) }
        session.onError = { [weak self] in self?.showError($0) }
        applyChrome(grid.resolvedTheme)
        if let responder = grid.subviews.first(where: { $0 is UITextView }) {
            captureLayout = PhoneCapture.observe(session, in: view, input: responder)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        captureLayout?()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusIfRequested()
    }

    func focusIfRequested() {
        guard session.options.keyboard, viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              !focusRequested else { return }
        focusRequested = session.view.focusInput()
    }

    private func applyChrome(_ theme: TerminalTheme) {
        view.backgroundColor = UIColor(terminal: theme.palette.background)
        setNeedsStatusBarAppearanceUpdate()
    }

    private func showError(_ detail: String) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Couldn’t connect to the terminal",
                                      message: "\(detail)\n\nThe demo peer is expected at \(session.options.endpoint.absoluteString).",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
            guard let self else { return }
            session.replay(session.options.scene)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }
}
#endif
