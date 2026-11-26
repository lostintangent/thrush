#if os(iOS)
import ThrushCore
import UIKit

/// UIKit owns the editable document only until its input method commits. The terminal owns all echo.
final class PhoneTerminalInput: UITextView, UITextViewDelegate, UITextPasteDelegate {
    private weak var terminal: TerminalMetalView?
    private lazy var terminalKeyCommands = makeKeyCommands()
    private var editingDepth = 0
    private var cursorRect = CGRect.zero
    private var viewportWidth: CGFloat = 0
    private var theme: TerminalTheme?
    private var ink: Terminal.RGB?
    private var paper: Terminal.RGB?
    private lazy var keyRow = KeyRow(
        onKey: { [weak self] key in self?.sendKey(key) },
        onHide: { [weak self] in _ = self?.resignFirstResponder() }
    )

    init(terminal: TerminalMetalView) {
        self.terminal = terminal
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        pasteDelegate = self
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        isScrollEnabled = false
        contentInsetAdjustmentBehavior = .never
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        writingToolsBehavior = .none
        allowsEditingTextAttributes = false
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []
        backgroundColor = .clear
        tintColor = .clear
        isOpaque = false
        inputAccessoryView = keyRow
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in self.matchKeyRowToWindow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The history scroll view handles terminal selection, scrolling and keyboard focus.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
    override var hasText: Bool { true }
    private var acceptsInput: Bool { terminal?.acceptsTerminalInput == true }
    override var canBecomeFirstResponder: Bool { acceptsInput && super.canBecomeFirstResponder }

    var showsKeyRow = true {
        didSet {
            guard showsKeyRow != oldValue else { return }
            keyRow.clearModifier()
            inputAccessoryView = showsKeyRow ? keyRow : nil
            if isFirstResponder { reloadInputViews() }
        }
    }

    /// UIKit measures the key row before the row joins the keyboard's window. A row that only then
    /// learns it is compact changes height as the keyboard arrives, and UIKit leaves the keyboard
    /// guide 16 points short of it. So the row takes the terminal window's size class from the start.
    private func matchKeyRowToWindow() {
        let sizeClass = traitCollection.verticalSizeClass
        guard sizeClass != .unspecified else { return }
        keyRow.traitOverrides.verticalSizeClass = sizeClass
        keyRow.updateTraitsIfNeeded()
    }

    /// Composition draws in the terminal's ink on its paper. The key row stays on the theme.
    func synchronize(cursorRect: CGRect, pointSize: CGFloat, theme: TerminalTheme, ink: Terminal.RGB, paper: Terminal.RGB) {
        if keyRow.isUserInteractionEnabled != acceptsInput {
            keyRow.isUserInteractionEnabled = acceptsInput
            keyRow.accessibilityElementsHidden = !acceptsInput
        }
        let width = terminal?.bounds.width ?? 0
        let themeChanged = self.theme != theme
        let inkChanged = self.ink != ink || self.paper != paper
        let fontChanged = font?.pointSize != pointSize
        guard themeChanged || inkChanged || fontChanged || self.cursorRect != cursorRect || viewportWidth != width else { return }
        self.cursorRect = cursorRect
        viewportWidth = width
        self.theme = theme
        self.ink = ink
        self.paper = paper
        if fontChanged { font = .monospacedSystemFont(ofSize: pointSize, weight: .regular) }
        if inkChanged {
            textColor = UIColor(terminalColor: ink)
            markedTextStyle = [
                .foregroundColor: UIColor(terminalColor: ink),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
        if themeChanged { keyRow.apply(theme) }
        layoutComposition()
    }

    private func layoutComposition() {
        guard let font, let terminal, let ink, let paper else { return }
        let marked = markedTextRange != nil
        let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2
        let width = min(terminal.bounds.width, max(cursorRect.width, measuredWidth))
        let x = min(cursorRect.minX, max(0, terminal.bounds.maxX - width))
        let rect = CGRect(x: x, y: cursorRect.minY, width: width,
                          height: max(cursorRect.height, ceil(font.lineHeight)))
        if frame != rect { frame = rect }
        backgroundColor = marked ? UIColor(terminalColor: paper) : .clear
        tintColor = marked ? UIColor(terminalColor: ink) : .clear
    }

    /// UITextInput implementations can call one another. Observe the complete edit after returning
    /// to the outermost call, when UIKit has updated both the text storage and its marked range.
    private func edit(_ action: () -> Void) {
        guard acceptsInput else { return }
        editingDepth += 1
        action()
        editingDepth -= 1
        if editingDepth == 0 { deliverCommittedText() }
    }

    func textViewDidChange(_ textView: UITextView) {
        if editingDepth == 0 { deliverCommittedText() }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        if let markedText, !markedText.isEmpty {
            edit { super.setMarkedText(markedText, selectedRange: selectedRange) }
        } else {
            clearDocument()
        }
    }

    override func unmarkText() { edit { super.unmarkText() } }
    override func insertText(_ text: String) { edit { super.insertText(text) } }

    override func replace(_ range: UITextRange, withText text: String) {
        edit { super.replace(range, withText: text) }
    }

    override func deleteBackward() {
        if text.isEmpty && markedTextRange == nil {
            sendKey(.backspace)
        } else {
            edit { super.deleteBackward() }
        }
    }

    private func deliverCommittedText() {
        guard acceptsInput else { clearDocument(); return }
        guard markedTextRange == nil, let committed = text, !committed.isEmpty else {
            layoutComposition()
            return
        }
        clearDocument()
        switch committed {
        case "\n", "\r": sendKey(.enter)
        case "\t": sendKey(.tab)
        default:
            if keyRow.controlArmed, committed.count == 1, let character = committed.first {
                sendKey(.character(character))
            } else {
                keyRow.clearModifier()
                terminal?.sendInput(.text(committed))
            }
        }
    }

    private func clearDocument() {
        editingDepth += 1
        if markedTextRange != nil { super.unmarkText() }
        if !text.isEmpty { text = "" }
        editingDepth -= 1
        layoutComposition()
    }

    func cancelPendingInput() {
        clearDocument()
        keyRow.clearModifier()
    }

    override func becomeFirstResponder() -> Bool {
        if !isFirstResponder, canBecomeFirstResponder {
            terminal?.beforeKeyboardMove?()
            matchKeyRowToWindow()
        }
        guard super.becomeFirstResponder() else { return false }
        terminal?.inputFocusDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        cancelPendingInput()
        if isFirstResponder { terminal?.beforeKeyboardMove?() }
        guard super.resignFirstResponder() else { return false }
        terminal?.inputFocusDidChange()
        return true
    }

    override func paste(_ sender: Any?) {
        guard acceptsInput else { return }
        terminal?.paste(from: .general)
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard acceptsInput else { return }
        super.paste(itemProviders: itemProviders)
    }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool {
        acceptsInput && super.canPaste(itemProviders)
    }

    // UIKit also delivers item-provider paste and drop operations through UITextPasteDelegate.
    func textPasteConfigurationSupporting(_ support: any UITextPasteConfigurationSupporting,
                                          performPasteOf attributedString: NSAttributedString,
                                          to textRange: UITextRange) -> UITextRange {
        pasteText(attributedString.string)
        return textRange
    }

    func pasteText(_ content: String) {
        guard acceptsInput, !content.isEmpty else { return }
        if markedTextRange != nil { unmarkText() }
        keyRow.clearModifier()
        terminal?.sendInput(.paste(content))
    }

    override func copy(_ sender: Any?) {
        if let selected = terminal?.selectedText, !selected.isEmpty {
            UIPasteboard.general.string = selected
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(terminalKey(_:)) { return acceptsInput && markedTextRange == nil }
        if action == #selector(copy(_:)) { return terminal?.selectedText?.isEmpty == false }
        if action == #selector(paste(_:)) { return acceptsInput && UIPasteboard.general.hasStrings }
        if action == #selector(cut(_:)) { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    private func sendKey(_ key: Terminal.Input.Key, modifiers: Terminal.Input.Modifiers = []) {
        guard acceptsInput else { return }
        var modifiers = modifiers
        if keyRow.controlArmed { modifiers.insert(.control) }
        keyRow.clearModifier()
        terminal?.sendInput(.key(key, modifiers: modifiers))
    }

    // UIKit binds unmodified arrows, Tab and several Control keys to local text editing before
    // delivering raw presses. Claim those commands while the remote terminal owns the caret.
    private static let navigation: [String: UIKeyboardHIDUsage] = [
        UIKeyCommand.inputUpArrow: .keyboardUpArrow, UIKeyCommand.inputDownArrow: .keyboardDownArrow,
        UIKeyCommand.inputLeftArrow: .keyboardLeftArrow, UIKeyCommand.inputRightArrow: .keyboardRightArrow,
        UIKeyCommand.inputHome: .keyboardHome, UIKeyCommand.inputEnd: .keyboardEnd,
        UIKeyCommand.inputPageUp: .keyboardPageUp, UIKeyCommand.inputPageDown: .keyboardPageDown,
        UIKeyCommand.inputEscape: .keyboardEscape, "\t": .keyboardTab,
    ]

    private func makeKeyCommands() -> [UIKeyCommand] {
        let modifiers: [UIKeyModifierFlags] = [[], .shift, .alternate, [.shift, .alternate],
                                              .control, [.control, .shift], [.control, .alternate],
                                              [.control, .alternate, .shift]]
        func command(_ input: String, _ flags: UIKeyModifierFlags) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(terminalKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            command.allowsAutomaticMirroring = false
            command.allowsAutomaticLocalization = false
            return command
        }
        let navigation = Self.navigation.keys.flatMap { key in modifiers.map { command(key, $0) } }
        let control = "abcdefghijklmnopqrstuvwxyz".map { command(String($0), .control) }
        return navigation + control
    }

    override var keyCommands: [UIKeyCommand]? {
        if !acceptsInput || markedTextRange != nil { return super.keyCommands }
        return terminalKeyCommands + (super.keyCommands ?? [])
    }

    @objc private func terminalKey(_ command: UIKeyCommand) {
        guard acceptsInput, markedTextRange == nil, let characters = command.input else { return }
        let code = Self.navigation[characters] ?? .keyboardErrorUndefined
        guard let (key, mods) = Self.hardwareKey(code, characters: characters, flags: command.modifierFlags) else { return }
        sendKey(key, modifiers: mods)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsInput, markedTextRange == nil else {
            super.pressesBegan(presses, with: event)
            return
        }
        var unhandled = presses
        for press in presses.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let key = press.key, !key.modifierFlags.contains(.command) else { continue }
            let printable = key.characters.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
            let characters = printable && !key.characters.isEmpty ? key.characters : key.charactersIgnoringModifiers
            guard let (input, modifiers) = Self.hardwareKey(key.keyCode, characters: characters,
                                                           flags: key.modifierFlags) else { continue }
            sendKey(input, modifiers: modifiers)
            unhandled.remove(press)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    static func hardwareKey(_ code: UIKeyboardHIDUsage, characters: String, flags: UIKeyModifierFlags)
        -> (Terminal.Input.Key, Terminal.Input.Modifiers)? {
        var modifiers = Terminal.Input.Modifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.alternate) { modifiers.insert(.alt) }
        if flags.contains(.control) { modifiers.insert(.control) }
        let key: Terminal.Input.Key
        switch code {
        case .keyboardUpArrow: key = .up
        case .keyboardDownArrow: key = .down
        case .keyboardLeftArrow: key = .left
        case .keyboardRightArrow: key = .right
        case .keyboardHome: key = .home
        case .keyboardEnd: key = .end
        case .keyboardPageUp: key = .pageUp
        case .keyboardPageDown: key = .pageDown
        case .keyboardDeleteForward: key = .delete
        case .keyboardDeleteOrBackspace: key = .backspace
        case .keyboardEscape: key = .escape
        case .keyboardTab: key = .tab
        case .keyboardReturnOrEnter, .keypadEnter: key = .enter
        case .keyboardInsert: key = .insert
        case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
             .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
            key = .function(code.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue + 1)
        default:
            // Physical printable keys go through the input method.
            guard modifiers.contains(.control), characters.count == 1,
                  let character = characters.first else { return nil }
            key = .character(character)
        }
        return (key, modifiers)
    }
}

extension TerminalMetalView {
    /// The standard edit command uses the system pasteboard. A packaged benchmark can use its own.
    package func paste(from pasteboard: UIPasteboard) {
        if let text = pasteboard.string { phoneInput.pasteText(text) }
    }
}

extension UIColor {
    convenience init(terminalColor rgb: Terminal.RGB) {
        self.init(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                  blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }
}
#endif
