#if os(iOS)
import Thrush
import SwiftUI
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

    func sceneWillEnterForeground(_ scene: UIScene) { host.session.setActive(true) }

    func sceneDidBecomeActive(_ scene: UIScene) {
        PhoneCapture.orient(scene)
        host.focusIfRequested()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        host.session.setActive(false)
    }
}

private extension UIColor {
    convenience init(terminal rgb: Terminal.RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                  blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

private final class PhoneHost: UIHostingController<DemoSurface> {
    let session: DemoSession
    private var focusRequested = false
    private var captureLayout: (() -> Void)?
    private var layoutTrace: PhoneLayoutTrace?
    private var noticeObservation: Task<Void, Never>?

    init() {
        let session = DemoSession(options: DemoOptions())
        self.session = session
        super.init(rootView: DemoSurface(session: session))
        // The live pane owns safe area and keyboard avoidance. The isolated render benchmark
        // uses the hosting controller's safe content area because it has no pane container.
        if session.options.benchmarkURL == nil && !session.options.checksToolbar { safeAreaRegions = [] }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // The pane draws beneath the status bar, so the status bar follows the pane's background.
    private var canvas: ColorScheme?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Under a navigation stack, SwiftUI matches the status bar to the bar's scheme, which the pane sets.
        if session.options.checksToolbar { return super.preferredStatusBarStyle }
        let scheme = canvas ?? (traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        return scheme == .light ? .darkContent : .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        session.onThemeChange = { [weak self] in self?.applyChrome($0) }
        session.onCanvasChange = { [weak self] in
            self?.canvas = $0
            self?.setNeedsStatusBarAppearanceUpdate()
        }
        applyChrome(session.view.resolvedTheme)
        session.onFirstUsable = { [weak self] in self?.focusIfRequested() }
        if !session.options.checksToolbar { captureLayout = PhoneCapture.observe(session, view: session.view, in: view) }
        // The trace forwards frame submissions to the capture hook it wraps.
        layoutTrace = PhoneLayoutTrace(terminal: session.view, host: self)
        if CommandLine.arguments.contains("--capture-state"), session.options.scene.capturesNotice {
            noticeObservation = Task { [weak self] in
                while !Task.isCancelled, self != nil {
                    self?.observeLayout()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutTrace?.recordLayout("host.layout")
        focusIfRequested()
        observeLayout()
    }

    private func observeLayout() {
        if session.options.checksToolbar, captureLayout == nil,
           let terminal = PhoneToolbarProof.terminal(in: view) {
            captureLayout = PhoneCapture.observe(session, view: terminal, in: view)
        }
        captureLayout?()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusIfRequested()
    }

    func focusIfRequested() {
        guard !focusRequested, session.options.keyboard, session.hasUsableSession || session.options.benchmarkURL != nil,
              session.view.window != nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        focusRequested = session.view.focusInput()
    }

    private func applyChrome(_ theme: TerminalTheme) {
        view.backgroundColor = UIColor(terminal: theme.palette.background)
        setNeedsStatusBarAppearanceUpdate()
    }
}
#endif
