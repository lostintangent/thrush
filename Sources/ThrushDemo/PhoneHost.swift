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
        host.input.clearModifier()
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
    let input = KeyboardResponder()
    private var focusRequested = false
    private var captureLayout: (() -> Void)?

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if session.view.theme != nil { return .lightContent }
        return traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let grid = session.view
        view.addSubview(input)
        view.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        input.isAccessibilityElement = false
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            grid.topAnchor.constraint(equalTo: safe.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(activateKeyboard))
        grid.addGestureRecognizer(tap)
        session.onThemeChange = { [weak self] in self?.applyChrome($0) }
        input.onInput = { [weak self] in self?.session.send($0) }
        session.onError = { [weak self] in self?.showError($0) }
        applyChrome(grid.resolvedTheme)
        captureLayout = PhoneCapture.observe(session, in: view, input: input)
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
        focusRequested = input.becomeFirstResponder()
    }

    @objc private func activateKeyboard() { input.becomeFirstResponder() }

    private func applyChrome(_ theme: TerminalTheme) {
        view.backgroundColor = UIColor(terminal: theme.palette.background)
        input.apply(theme)
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

/// Native input and the keyboard-mounted controls share one commit path. The grid's bottom
/// constraint follows keyboardLayoutGuide, which already includes this accessory.
private final class KeyboardResponder: UIView, UIKeyInput {
    var onInput: ((Terminal.Input) -> Void)?
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { keys }
    var hasText: Bool { true }

    private var ctrl = false
    private var theme = TerminalTheme.slateDark
    private let control = UIButton(type: .system)
    private let separator = UIView()
    private lazy var keys = makeAccessory()

    func insertText(_ text: String) {
        if ctrl, text.unicodeScalars.count == 1, let ascii = text.uppercased().utf8.first, (64...95).contains(ascii) {
            onInput?(.text(String(Unicode.Scalar(ascii - 64))))
        } else {
            onInput?(text == "\n" ? .key(.enter) : .text(text))
        }
        clearModifier()
    }
    func deleteBackward() {
        onInput?(.key(.backspace))
        clearModifier()
    }
    override func resignFirstResponder() -> Bool {
        clearModifier()
        return super.resignFirstResponder()
    }

    func clearModifier() {
        guard ctrl else { return }
        ctrl = false
        refreshControl()
    }

    func apply(_ theme: TerminalTheme) {
        self.theme = theme
        keys.tintColor = UIColor(terminal: theme.palette.foreground)
        keys.backgroundColor = UIColor(terminal: theme.hostBacking)
        separator.backgroundColor = UIColor(terminal: theme.separator)
        refreshControl()
    }

    private func makeAccessory() -> UIInputView {
        let accessory = UIInputView(frame: CGRect(x: 0, y: 0, width: 393, height: 44), inputViewStyle: .keyboard)
        accessory.autoresizingMask = [.flexibleWidth]
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        accessory.addSubview(stack)
        let safe = accessory.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            stack.topAnchor.constraint(equalTo: accessory.topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        let items: [(String, String?, Terminal.Input.Key?)] = [
            ("Esc", nil, .escape), ("Ctrl", nil, nil), ("Tab", nil, .tab),
            ("Left arrow", "arrow.left", .left), ("Up arrow", "arrow.up", .up),
            ("Down arrow", "arrow.down", .down), ("Right arrow", "arrow.right", .right),
        ]
        for (name, symbol, key) in items {
            let button = name == "Ctrl" ? control : UIButton(type: .system)
            if let symbol {
                let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
                button.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
            } else {
                button.setTitle(name, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            }
            button.accessibilityLabel = name
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if let key {
                    onInput?(.key(key))
                    clearModifier()
                } else {
                    ctrl.toggle()
                    refreshControl()
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        separator.translatesAutoresizingMaskIntoConstraints = false
        accessory.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.centerXAnchor.constraint(equalTo: stack.arrangedSubviews[2].trailingAnchor),
            separator.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 18),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        return accessory
    }

    private func refreshControl() {
        control.accessibilityTraits = ctrl ? [.button, .selected] : [.button]
        control.backgroundColor = ctrl ? UIColor(terminal: theme.selection) : .clear
        control.setTitleColor(UIColor(terminal: ctrl ? theme.selectionInk : theme.palette.foreground), for: .normal)
        control.layer.cornerRadius = 12
    }
}
#endif
