#if os(iOS)
import ThrushCore
import UIKit

/// A glass capsule that floats above the keyboard with the keys a terminal needs and Hide Keyboard.
/// Its modifier key arms Control for the next key and raises a chooser that offers Option or Shift instead.
final class KeyRow: UIView {
    /// Portrait floats a 48-point capsule 12 points above the keyboard. Landscape, where every
    /// row counts, floats a 36-point capsule 8 points above it. The grid's own bottom inset keeps
    /// the last row clear of either.
    static func height(compact: Bool) -> CGFloat { compact ? 44 : 60 }
    /// The modifier the next key carries, if any. Only one is armed at a time.
    private(set) var armed: Terminal.Input.Modifiers = []
    private var theme: TerminalTheme = .slateDark
    private let glass = UIVisualEffectView()
    private lazy var glassHeight = glass.heightAnchor.constraint(equalToConstant: capsuleHeight)
    private let stack = UIStackView()
    private let modifier = UIButton(type: .system)
    private let dividers = [UIView(), UIView()]
    private let onKey: (Terminal.Input.Key) -> Void
    /// UIKit sends a touch above the keyboard's accessory to the window beneath, so the chooser floats in the
    /// terminal's window, pinned to the keyboard there, while the row stays in the keyboard's own window.
    private weak var host: UIView?
    private lazy var chooser = ModifierChooser { [weak self] choice in self?.arm(choice == self?.armed ? [] : choice) }
    private var chooserPlacement: [NSLayoutConstraint] = []
    /// While a hold slides across the chooser: the modifier it would arm, and the one armed before it began.
    private var sliding: (choice: Terminal.Input.Modifiers?, before: Terminal.Input.Modifiers)?
    private let selection = UISelectionFeedbackGenerator()

    private var compact: Bool { traitCollection.verticalSizeClass == .compact }
    private var capsuleHeight: CGFloat { compact ? 36 : 48 }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height(compact: compact)) }

    init(host: UIView?, onKey: @escaping (Terminal.Input.Key) -> Void, onHide: @escaping () -> Void) {
        self.host = host
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
            let button = name == "Ctrl" ? modifier : UIButton(type: .system)
            if let symbol {
                button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
            } else if key != nil {
                button.setTitle(name, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
            }
            button.accessibilityLabel = name
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if let key {
                    onKey(key)
                } else if button === modifier {
                    arm(armed.isEmpty ? .control : [])
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
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(slide(_:)))
        hold.minimumPressDuration = 0.35
        modifier.addGestureRecognizer(hold)
        modifier.accessibilityIdentifier = "terminal.modifier"
        modifier.accessibilityCustomActions = ModifierChooser.choices.map { choice in
            UIAccessibilityCustomAction(name: choice.name) { [weak self] _ in
                self?.arm(choice.modifier)
                return true
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshBacking),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil
        )
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
            self.glassHeight.constant = self.capsuleHeight
            // UIKit first sizes a row that joins the keyboard from its frame, so a detached row keeps
            // its frame at its own height. A stale frame leaves the keyboard guide short of the row.
            if self.window == nil { self.frame.size.height = Self.height(compact: self.compact) }
            self.invalidateIntrinsicContentSize()
            self.refreshModifier()
        }
        apply(.slateDark, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        // UIKit animates the view holding the key row to the new keyboard width. Keep the
        // controls in destination coordinates throughout that transform.
        UIView.performWithoutAnimation {
            super.layoutSubviews()
            glass.layoutIfNeeded()
            stack.layoutIfNeeded()
        }
        placeChooser()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // A compact capsule's keys reach down into the float to keep 44-point targets.
        guard point.y >= glass.frame.maxY, point.y < 44 else { return super.hitTest(point, with: event) }
        return super.hitTest(CGPoint(x: point.x, y: glass.frame.maxY - 1), with: event)
    }

    func clearModifier() {
        guard !armed.isEmpty else { return }
        arm([])
    }

    /// Arms one modifier for the next key, or none, and raises the chooser while one is armed.
    private func arm(_ next: Terminal.Input.Modifiers) {
        let changed = next != armed
        armed = next
        refreshModifier()
        showChooser(!armed.isEmpty)
        guard changed, let choice = ModifierChooser.choices.first(where: { $0.modifier == armed }) else { return }
        let announcement = NSAttributedString(string: "\(choice.name) applies to the next key.",
                                              attributes: [.accessibilitySpeechQueueAnnouncement: true])
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    /// Holding the modifier key raises the chooser, and the finger slides along it to the modifier it lifts on.
    /// Lifting far from the chooser leaves the modifier as it was.
    @objc private func slide(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: self)
        let frame = chooserFrame
        let choice = frame.insetBy(dx: -44, dy: -44).contains(point) ? chooser.choice(at: point.x - frame.minX) : nil
        switch hold.state {
        case .began:
            sliding = (choice, armed)
            selection.selectionChanged()
            showChooser(true)
        case .changed:
            guard let before = sliding?.before, sliding?.choice != choice else { return }
            sliding = (choice, before)
            if choice != nil { selection.selectionChanged() }
        default:
            let next = hold.state == .ended ? choice ?? sliding?.before : sliding?.before
            sliding = nil
            arm(next ?? armed)
            return
        }
        refreshModifier()
    }

    /// Where the chooser floats in the row's coordinates: its Ctrl centered over the modifier key, 8 points above
    /// the capsule.
    private var chooserFrame: CGRect {
        let key = modifier.convert(modifier.bounds, to: self)
        let size = ModifierChooser.size(compact: compact)
        let x = min(max(8, key.midX - ModifierChooser.firstCenter), bounds.width - size.width - 8)
        return CGRect(origin: CGPoint(x: x, y: glass.frame.minY - 8 - size.height), size: size)
    }

    /// The keyboard spans the window it floats over, so the row's coordinates are the keyboard guide's there.
    private func placeChooser() {
        guard chooserPlacement.count == 4 else { return }
        let frame = chooserFrame
        for (constraint, constant) in zip(chooserPlacement, [frame.minX, frame.maxY, frame.width, frame.height]) {
            constraint.constant = constant
        }
    }

    private func showChooser(_ shows: Bool) {
        guard shows != chooser.shown else { return }
        if shows {
            guard window != nil, let canvas = host?.window else { return }
            if chooser.superview !== canvas {
                chooser.removeFromSuperview()
                canvas.addSubview(chooser)
                let guide = canvas.keyboardLayoutGuide
                chooserPlacement = [chooser.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                                    chooser.bottomAnchor.constraint(equalTo: guide.topAnchor),
                                    chooser.widthAnchor.constraint(equalToConstant: 0),
                                    chooser.heightAnchor.constraint(equalToConstant: 0)]
                NSLayoutConstraint.activate(chooserPlacement)
            }
            canvas.bringSubviewToFront(chooser)
            placeChooser()
            canvas.layoutIfNeeded()
        }
        chooser.shown = shows
        chooser.accessibilityElementsHidden = !shows
        refreshModifier()
        guard chooser.superview != nil else { return }
        // The chooser rises out of the modifier key with a short spring, or cross-fades under Reduce Motion.
        let frame = chooserFrame, key = modifier.convert(modifier.bounds, to: self)
        let still = UIAccessibility.isReduceMotionEnabled
        let sunk = still ? .identity : CGAffineTransform(translationX: key.midX - frame.midX, y: frame.height / 2 + 8)
            .scaledBy(x: 0.4, y: 0.4)
        if shows {
            // A chooser lowered and raised again before it's gone rises from where it is.
            if chooser.layer.presentation().map({ $0.opacity == 0 }) ?? true { chooser.transform = sunk }
            UIView.animate(springDuration: still ? 0.2 : 0.32, bounce: still ? 0 : 0.18, options: .allowUserInteraction) {
                self.chooser.alpha = 1
                self.chooser.transform = .identity
            }
        } else {
            UIView.animate(springDuration: 0.2, bounce: 0, options: .beginFromCurrentState) {
                self.chooser.alpha = 0
                self.chooser.transform = sunk
            } completion: { [chooser] _ in
                if !chooser.shown { chooser.removeFromSuperview() }
            }
        }
    }

    func apply(_ theme: TerminalTheme, force: Bool = false) {
        guard force || self.theme != theme else { return }
        self.theme = theme
        let ink = UIColor(terminalColor: theme.palette.foreground)
        tintColor = ink
        // Dividers are the key ink at 30%, so they keep their contrast on whatever the glass shows.
        for divider in dividers { divider.backgroundColor = ink.withAlphaComponent(0.3) }
        if theme == .slateDark { overrideUserInterfaceStyle = .dark }
        else if theme == .slateLight { overrideUserInterfaceStyle = .light }
        else { overrideUserInterfaceStyle = .unspecified }
        chooser.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        refreshBacking()
        refreshModifier()
    }

    @objc private func refreshBacking() {
        Self.back(glass, theme: theme)
        Self.back(chooser.glass, theme: theme)
    }

    /// Glass, or the theme's opaque backing under Reduce Transparency.
    static func back(_ glass: UIVisualEffectView, theme: TerminalTheme) {
        let opaque = UIAccessibility.isReduceTransparencyEnabled
        if opaque {
            glass.effect = nil
        } else if glass.effect == nil {
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = true
            glass.effect = effect
        }
        glass.backgroundColor = opaque ? UIColor(terminalColor: theme.opaqueBacking) : nil
    }

    /// A key's title, filled with the selection color while it's armed or chosen.
    static func chip(_ title: String, filled: Bool, theme: TerminalTheme, compact: Bool) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: 15, weight: .medium)
            return attributes
        }
        config.contentInsets = .zero
        config.cornerStyle = .capsule
        let inset: CGFloat = compact ? 4 : 8
        config.background.backgroundInsets = .init(top: inset, leading: 2, bottom: inset, trailing: 2)
        config.baseForegroundColor = UIColor(terminalColor: filled ? theme.selectionInk : theme.palette.foreground)
        config.background.backgroundColor = filled ? UIColor(terminalColor: theme.selection) : .clear
        return config
    }

    /// The modifier key names what the next key carries, and the chooser fills the modifier under a sliding finger.
    private func refreshModifier() {
        let choice = ModifierChooser.choices.first { $0.modifier == armed } ?? ModifierChooser.choices[0]
        chooser.apply(theme, compact: compact, chosen: sliding.map { $0.choice ?? [] } ?? armed)
        modifier.configuration = Self.chip(choice.key, filled: !armed.isEmpty, theme: theme, compact: compact)
        modifier.accessibilityLabel = choice.name
        modifier.accessibilityTraits = armed.isEmpty ? [.button] : [.button, .selected]
        modifier.accessibilityValue = armed.isEmpty ? "Off" : "Armed"
        modifier.accessibilityHint = armed.isEmpty ? "Applies Control to the next key." : "Disarms \(choice.name)."
    }
}

/// The modifiers the key row offers, in a glass capsule above its modifier key.
private final class ModifierChooser: UIView {
    struct Choice {
        let modifier: Terminal.Input.Modifiers
        /// The chooser's title, the modifier key's shorter one, and the name VoiceOver speaks.
        let title: String, key: String, name: String
        let width: CGFloat
    }

    static let choices = [
        Choice(modifier: .control, title: "Ctrl", key: "Ctrl", name: "Control", width: 56),
        Choice(modifier: .alt, title: "Option", key: "Opt", name: "Option", width: 72),
        Choice(modifier: .shift, title: "Shift", key: "Shift", name: "Shift", width: 60),
    ]
    private static let margin: CGFloat = 6
    static var firstCenter: CGFloat { margin + choices[0].width / 2 }
    static func size(compact: Bool) -> CGSize {
        CGSize(width: 2 * margin + choices.reduce(0) { $0 + $1.width }, height: compact ? 36 : 48)
    }

    let glass = UIVisualEffectView()
    var shown = false
    private let buttons: [UIButton]

    init(onChoose: @escaping (Terminal.Input.Modifiers) -> Void) {
        buttons = Self.choices.map { choice in
            let button = UIButton(type: .system)
            button.accessibilityLabel = choice.name
            button.accessibilityIdentifier = "terminal.modifier.\(choice.name.lowercased())"
            button.addAction(UIAction { _ in onChoose(choice.modifier) }, for: .touchUpInside)
            return button
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0
        glass.cornerConfiguration = .capsule()
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        for button in buttons { glass.contentView.addSubview(button) }
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x = Self.margin
        for (button, choice) in zip(buttons, Self.choices) {
            button.frame = CGRect(x: x, y: 0, width: choice.width, height: bounds.height)
            x += choice.width
        }
    }

    /// Every choice takes taps across its whole column, 44 points tall even on the compact capsule.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let reach = max(0, 44 - bounds.height) / 2
        guard shown, bounds.insetBy(dx: 0, dy: -reach).contains(point) else { return nil }
        return buttons[index(at: point.x)]
    }

    /// The choice under a point this far from the chooser's leading edge.
    func choice(at x: CGFloat) -> Terminal.Input.Modifiers { Self.choices[index(at: x)].modifier }

    private func index(at x: CGFloat) -> Int {
        var edge = Self.margin
        return Self.choices.firstIndex { choice in
            edge += choice.width
            return x < edge
        } ?? Self.choices.count - 1
    }

    func apply(_ theme: TerminalTheme, compact: Bool, chosen: Terminal.Input.Modifiers) {
        for (button, choice) in zip(buttons, Self.choices) {
            button.configuration = KeyRow.chip(choice.title, filled: choice.modifier == chosen, theme: theme, compact: compact)
            button.accessibilityTraits = choice.modifier == chosen ? [.button, .selected] : [.button]
        }
    }
}
#endif
