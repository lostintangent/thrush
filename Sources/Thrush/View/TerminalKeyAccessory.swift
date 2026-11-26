#if os(iOS)
import ThrushCore
import UIKit

/// A glass capsule that floats above the keyboard with the keys a terminal needs and Hide Keyboard.
final class TerminalKeyAccessory: UIView {
    /// Portrait floats a 48-point capsule 12 points above the keyboard. Landscape, where every
    /// row counts, floats a 36-point capsule 8 points above it. The grid's own bottom inset keeps
    /// the last row clear of either.
    static func height(compact: Bool) -> CGFloat { compact ? 44 : 60 }
    private(set) var controlArmed = false
    private var theme: TerminalTheme = .slateDark
    private let glass = UIVisualEffectView()
    private lazy var glassHeight = glass.heightAnchor.constraint(equalToConstant: capsuleHeight)
    private let stack = UIStackView()
    private let control = UIButton(type: .system)
    private let dividers = [UIView(), UIView()]
    private let onKey: (Terminal.Input.Key) -> Void

    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var capsuleHeight: CGFloat { compact ? 36 : 48 }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height(compact: compact)) }

    init(onKey: @escaping (Terminal.Input.Key) -> Void, onHide: @escaping () -> Void) {
        self.onKey = onKey
        super.init(frame: CGRect(x: 0, y: 0, width: 393, height: Self.height(compact: false)))
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        glass.cornerConfiguration = .capsule()
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.distribution = .fillEqually
        stack.semanticContentAttribute = .forceLeftToRight
        glass.contentView.addSubview(stack)
        // Narrow screens give up the side margins before any key drops below 44 points.
        let preferredWidth = glass.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh
        let margins = [
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ]
        for margin in margins { margin.priority = .required - 1 }
        NSLayoutConstraint.activate(margins + [
            preferredWidth,
            glass.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            glass.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glassHeight,
            stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])
        let items: [(String, String?, Terminal.Input.Key?)] = [
            ("Esc", nil, .escape), ("Ctrl", nil, nil), ("Tab", nil, .tab),
            ("Left arrow", "arrow.left", .left), ("Up arrow", "arrow.up", .up),
            ("Down arrow", "arrow.down", .down), ("Right arrow", "arrow.right", .right),
            ("Hide Keyboard", "keyboard.chevron.compact.down", nil),
        ]
        for (name, symbol, key) in items {
            let button = name == "Ctrl" ? control : UIButton(type: .system)
            if let symbol {
                button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            } else if key != nil {
                button.setTitle(name, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            }
            button.accessibilityLabel = name == "Ctrl" ? "Control" : name
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if let key {
                    onKey(key)
                } else if button === control {
                    controlArmed.toggle()
                    refreshControl()
                } else {
                    onHide()
                }
            }, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
        }
        // Dividers set apart the arrows from the keys before them and from Hide Keyboard.
        for (divider, index) in zip(dividers, [2, 6]) {
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.isUserInteractionEnabled = false
            glass.contentView.addSubview(divider)
            NSLayoutConstraint.activate([
                divider.centerXAnchor.constraint(equalTo: stack.arrangedSubviews[index].trailingAnchor),
                divider.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
                divider.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 5.0 / 12),
                divider.widthAnchor.constraint(equalToConstant: 1),
            ])
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBacking),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
            self.glassHeight.constant = self.capsuleHeight
            self.invalidateIntrinsicContentSize()
            self.refreshControl()
        }
        apply(.slateDark, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        // UIKit animates the accessory's host to the new keyboard width. Keep the
        // controls in destination coordinates throughout that transform.
        UIView.performWithoutAnimation {
            super.layoutSubviews()
            glass.layoutIfNeeded()
            stack.layoutIfNeeded()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A compact capsule's keys reach down into the float to keep 44-point targets.
        guard point.y >= glass.frame.maxY, point.y < 44 else { return super.hitTest(point, with: event) }
        return super.hitTest(CGPoint(x: point.x, y: glass.frame.maxY - 1), with: event)
    }

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
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        if opaque {
            glass.effect = nil
        } else if glass.effect == nil {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            glass.effect = effect
        }
        glass.backgroundColor = opaque ? UIColor(terminalColor: theme.opaqueBacking) : nil
        for divider in dividers { divider.backgroundColor = UIColor(terminalColor: theme.separator) }
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
        config.cornerStyle = .capsule
        let inset: CGFloat = compact ? 4 : 8
        config.background.backgroundInsets = .init(top: inset, leading: 2, bottom: inset, trailing: 2)
        config.baseForegroundColor = UIColor(terminalColor: controlArmed ? theme.selectionInk : theme.palette.foreground)
        config.background.backgroundColor = controlArmed ? UIColor(terminalColor: theme.selection) : .clear
        control.configuration = config
        control.accessibilityTraits = controlArmed ? [.button, .selected] : [.button]
        control.accessibilityValue = controlArmed ? "Armed" : "Off"
        control.accessibilityHint = "Applies Control to the next key."
    }
}
#endif
