#if os(iOS)
import ThrushCore
import UIKit

/// Adopt this protocol on a custom keyboard accessory view to send keys to its terminal.
@MainActor public protocol TerminalInputAccessory: AnyObject {
    /// The pane installs this handler while your view is the active accessory.
    /// Pass a UIKit key-command input, such as `UIKeyCommand.inputUpArrow`, or one character.
    /// For example, `onKeyPress?("c", .control)` sends Control-C and `onKeyPress?("\r", [])` sends Return.
    var onKeyPress: ((_ input: String, _ modifiers: UIKeyModifierFlags) -> Void)? { get set }
}

/// The controls attached to the system keyboard for this viewport.
public enum TerminalKeyboardAccessory: Equatable {
    /// The built-in Escape, Control, Tab and arrow keys.
    case standard
    /// Hides the terminal key row above the software keyboard.
    case none
    /// Displays a host-supplied view whose controls send terminal input.
    case custom(UIView & TerminalInputAccessory)

    /// Compares the selected accessory, using view identity for custom accessories.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.standard, .standard), (.none, .none): true
        case let (.custom(a), .custom(b)): a === b
        default: false
        }
    }
}

/// The input view follows the keyboard's presentation and supplies one material for the whole row.
final class TerminalKeyAccessory: UIInputView {
    private(set) var controlArmed = false
    private var theme: TerminalTheme = .slateDark
    private let control = UIButton(type: .system)
    private let separator = UIView()
    private let onKey: (Terminal.Input.Key) -> Void

    init(onKey: @escaping (Terminal.Input.Key) -> Void) {
        self.onKey = onKey
        super.init(frame: CGRect(x: 0, y: 0, width: 393, height: 44), inputViewStyle: .keyboard)
        autoresizingMask = [.flexibleWidth]
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fillEqually
        stack.semanticContentAttribute = .forceLeftToRight
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
        ])
        let items: [(String, String?, Terminal.Input.Key?)] = [
            ("Esc", nil, .escape), ("Ctrl", nil, nil), ("Tab", nil, .tab),
            ("Left arrow", "arrow.left", .left), ("Up arrow", "arrow.up", .up),
            ("Down arrow", "arrow.down", .down), ("Right arrow", "arrow.right", .right),
        ]
        for (name, symbol, key) in items {
            let button = key == nil ? control : UIButton(type: .system)
            if let symbol {
                button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)), for: .normal)
            } else if key != nil {
                button.setTitle(name, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            }
            button.accessibilityLabel = name == "Ctrl" ? "Control" : name
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if let key {
                    onKey(key)
                } else {
                    controlArmed.toggle()
                    refreshControl()
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isUserInteractionEnabled = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.centerXAnchor.constraint(equalTo: stack.arrangedSubviews[2].trailingAnchor),
            separator.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            separator.heightAnchor.constraint(equalToConstant: 18),
            separator.widthAnchor.constraint(equalToConstant: 1),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBacking),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
        apply(.slateDark, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func clearModifier() {
        guard controlArmed else { return }
        controlArmed = false
        refreshControl()
    }

    func apply(_ theme: TerminalTheme, force: Bool = false) {
        guard force || self.theme != theme else { return }
        self.theme = theme
        tintColor = UIColor(terminalColor: theme.palette.foreground)
        if theme == .slateDark { overrideUserInterfaceStyle = .dark }
        else if theme == .slateLight { overrideUserInterfaceStyle = .light }
        else { overrideUserInterfaceStyle = .unspecified }
        refreshBacking()
        refreshControl()
    }

    @objc private func refreshBacking() {
        backgroundColor = UIAccessibility.isReduceTransparencyEnabled ? UIColor(terminalColor: theme.hostBacking) : nil
        separator.backgroundColor = UIColor(terminalColor: theme.separator)
    }

    private func refreshControl() {
        var config = UIButton.Configuration.plain()
        config.title = "Ctrl"
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        config.contentInsets = .zero
        config.imagePadding = 2
        config.cornerStyle = .capsule
        config.background.backgroundInsets = .init(top: 7, leading: 2, bottom: 7, trailing: 2)
        config.baseForegroundColor = UIColor(terminalColor: controlArmed ? theme.selectionInk : theme.palette.foreground)
        config.background.backgroundColor = controlArmed ? UIColor(terminalColor: theme.selection) : .clear
        if controlArmed {
            config.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        }
        control.configuration = config
        control.accessibilityTraits = controlArmed ? [.button, .selected] : [.button]
        control.accessibilityValue = controlArmed ? "Armed" : "Off"
        control.accessibilityHint = "Applies Control to the next key."
    }
}
#endif
