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
    private let controller = PhoneHostingController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        switch controller.session.options.customTheme ? .dark : controller.session.options.appearance {
        case .dark: window.overrideUserInterfaceStyle = .dark
        case .light: window.overrideUserInterfaceStyle = .light
        case .system: break
        }
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneWillEnterForeground(_ scene: UIScene) { controller.session.setActive(true) }

    func sceneDidBecomeActive(_ scene: UIScene) {
        PhoneCapture.orient(scene)
        controller.focusIfRequested()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        controller.session.setActive(false)
    }
}

private extension UIColor {
    convenience init(terminal rgb: Terminal.RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                  blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}

private final class PhoneHostingController: UIHostingController<DemoSurface> {
    let session: DemoSession
    private var focusRequested = false
    private var captureLayout: (() -> Void)?
    private var layoutTrace: PhoneLayoutTrace?
    private var stateObservation: Task<Void, Never>?

    init() {
        let session = DemoSession(options: DemoOptions())
        self.session = session
        super.init(rootView: DemoSurface(session: session))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // The terminal view draws beneath the status bar, so the status bar follows its background.
    private var canvas: ColorScheme?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Under a navigation stack, SwiftUI matches the status bar to the bar's scheme, which the view sets.
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
        if session.options.checksToolbar && session.options.keyboard {
            // The toolbar proof mounts only the public view, so keep asking until its terminal is in the window.
            Task { [weak self] in
                while let controller = self, !controller.focusRequested {
                    controller.focusIfRequested()
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
        }
        if !session.options.checksToolbar { captureLayout = PhoneCapture.observe(session, view: session.view, in: view) }
        // The trace forwards frame submissions to the capture hook it wraps.
        layoutTrace = PhoneLayoutTrace(terminal: session.view, controller: self)
        if CommandLine.arguments.contains("--capture-state"), session.options.scene.capturesSessionState {
            stateObservation = Task { [weak self] in
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
        guard !focusRequested, session.options.keyboard,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        if session.options.checksToolbar {
            focusRequested = PhoneToolbarProof.terminal(in: view)?.focusInput() ?? false
        } else if session.hasUsableSession || session.options.benchmarkURL != nil, session.view.window != nil {
            focusRequested = session.view.focusInput()
        }
    }

    private func applyChrome(_ theme: TerminalTheme) {
        view.backgroundColor = UIColor(terminal: theme.palette.background)
        setNeedsStatusBarAppearanceUpdate()
    }
}
#endif
