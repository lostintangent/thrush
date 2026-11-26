#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
import UIKit

@MainActor
@Test func phoneTextInputCommitsMarkedTextExactlyOnce() throws {
    let terminal = Terminal(size: .init(columns: 40, rows: 20))
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let input = view.phoneInput
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    input.synchronize(cursorRect: .init(x: 92, y: 44, width: 8, height: 18), pointSize: 13, theme: .slateDark,
                      ink: TerminalTheme.slateDark.palette.foreground, paper: TerminalTheme.slateDark.palette.background)

    input.setMarkedText("つ", selectedRange: NSRange(location: 1, length: 0))
    input.setMarkedText("つばさ", selectedRange: NSRange(location: 3, length: 0))
    #expect(input.markedTextRange != nil)
    #expect(input.frame.minX == 92 && input.frame.minY == 44)
    #expect(sent.isEmpty)
    input.synchronize(cursorRect: .init(x: 92, y: 44, width: 8, height: 18), pointSize: 13, theme: .slateLight,
                      ink: TerminalTheme.slateLight.palette.foreground, paper: TerminalTheme.slateLight.palette.background)
    #expect(input.markedTextRange != nil && input.text == "つばさ")
    input.insertText("翼")
    input.unmarkText()
    #expect(sent == [Array("翼".utf8)])
    #expect(input.markedTextRange == nil && input.text.isEmpty)

    input.setMarkedText("鳥", selectedRange: NSRange(location: 1, length: 0))
    input.unmarkText()
    input.unmarkText()
    #expect(sent == [Array("翼".utf8), Array("鳥".utf8)])

    input.setMarkedText("とり", selectedRange: NSRange(location: 2, length: 0))
    input.cancelPendingInput()
    input.unmarkText()
    #expect(sent.count == 2)

    input.insertText("🐦")
    input.deleteBackward()
    input.insertText("\n")
    #expect(Array(sent.suffix(3)) == [Array("🐦".utf8), [0x7F], [0x0D]])
}

@MainActor
@Test func phoneAccessoryAndHardwareKeysUseTerminalModes() throws {
    var terminal = Terminal(size: .init(columns: 40, rows: 20))
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let input = view.phoneInput
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    let accessory = try #require(input.inputAccessoryView)
    let stack = try #require(accessoryStack(accessory))
    let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
    let control = try #require(buttons.first { $0.accessibilityLabel == "Control" })
    let arrow = try #require(buttons.first { $0.accessibilityLabel == "Up arrow" })
    #expect(buttons.count == 8)
    accessory.frame = .init(x: 0, y: 0, width: 320, height: TerminalKeyAccessory.height(compact: false))
    accessory.layoutIfNeeded()
    #expect(buttons.allSatisfy { $0.bounds.width >= 44 && $0.bounds.height >= 44 })

    control.sendActions(for: .touchUpInside)
    #expect(control.accessibilityTraits.contains(.selected))
    input.insertText("c")
    #expect(!control.accessibilityTraits.contains(.selected))
    arrow.sendActions(for: .touchUpInside)
    _ = terminal.receive(Array("\u{1B}[?1h".utf8))
    arrow.sendActions(for: .touchUpInside)
    control.sendActions(for: .touchUpInside)
    arrow.sendActions(for: .touchUpInside)
    #expect(sent == [[3], [27, 91, 65], [27, 79, 65], [27, 91, 49, 59, 53, 65]])

    control.sendActions(for: .touchUpInside)
    input.cancelPendingInput()
    #expect(!control.accessibilityTraits.contains(.selected))

    let (key, modifiers) = try #require(PhoneTerminalInput.hardwareKey(.keyboardLeftArrow, characters: "", flags: [.alternate, .shift]))
    #expect(terminal.encode(.key(key, modifiers: modifiers)) == [27, 91, 49, 59, 52, 68])
    #expect(PhoneTerminalInput.hardwareKey(.keyboardE, characters: "e", flags: [.alternate]) == nil)
    let shortcut = try #require(input.keyCommands?.first { $0.input == "a" && $0.modifierFlags == .control })
    #expect(shortcut.wantsPriorityOverSystemBehavior)
    let action = try #require(shortcut.action)
    _ = input.perform(action, with: shortcut)
    #expect(sent.last == [1])
    input.setMarkedText("つ", selectedRange: NSRange(location: 1, length: 0))
    #expect(!input.canPerformAction(action, withSender: shortcut))
}

@MainActor
@Test func phonePasteUsesThePastePath() async throws {
    var terminal = Terminal(size: .init(columns: 40, rows: 20))
    _ = terminal.receive(Array("\u{1B}[?2004h".utf8))
    let view = TerminalView(frame: .zero)
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    // Exercise UIKit's paste coordinator without touching the user's system pasteboard.
    let provider = NSItemProvider(object: "a\nb" as NSString)
    view.phoneInput.paste(itemProviders: [provider])
    let deadline = ContinuousClock.now + .seconds(3)
    while sent.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(sent == [Array("\u{1B}[200~a\rb\u{1B}[201~".utf8)])
}

@MainActor
@Test func phoneAccessoryUsesOnlyTheKeyboardHostResizeAnimation() throws {
    let window = UIWindow(frame: .init(x: 0, y: 0, width: 874, height: 402))
    let host = UIView(frame: window.bounds)
    let accessory = TerminalKeyAccessory(onKey: { _ in }, onHide: {})
    window.addSubview(host)
    host.addSubview(accessory)
    window.isHidden = false
    defer { window.isHidden = true }

    accessory.frame = .init(x: 0, y: 0, width: 750, height: accessory.intrinsicContentSize.height)
    accessory.layoutIfNeeded()
    let stack = try #require(accessoryStack(accessory))
    let buttons = stack.arrangedSubviews
    #expect(buttons.count == 8)
    CATransaction.flush()

    // UIKit gives the accessory its destination bounds and animates the keyboard host.
    // Auto Layout still runs with the host's inherited animation context.
    UIView.animate(withDuration: 5, delay: 0, options: .curveLinear) {
        host.transform = .init(scaleX: 0.6, y: 1)
        UIView.performWithoutAnimation { accessory.bounds.size.width = 402 }
        accessory.layoutIfNeeded()
    }
    CATransaction.flush()

    #expect(!(host.layer.animationKeys() ?? []).isEmpty)
    for view in [stack] + buttons {
        let presented = try #require(view.layer.presentation())
        #expect(abs(presented.bounds.width - view.bounds.width) <= 1)
        #expect(abs(presented.position.x - view.layer.position.x) <= 1)
    }
    #expect(buttons.allSatisfy { $0.bounds.width >= 44 })
}

@MainActor
@Test func compactKeyRowKeysReachIntoTheFloat() throws {
    let window = UIWindow(frame: .init(x: 0, y: 0, width: 874, height: 402))
    let accessory = TerminalKeyAccessory(onKey: { _ in }, onHide: {})
    window.addSubview(accessory)
    window.isHidden = false
    defer { window.isHidden = true }
    accessory.traitOverrides.verticalSizeClass = .compact
    accessory.updateTraitsIfNeeded()
    #expect(accessory.intrinsicContentSize.height == 44)
    accessory.frame = .init(x: 0, y: 0, width: 750, height: 44)
    accessory.layoutIfNeeded()

    let buttons = try #require(accessoryStack(accessory)?.arrangedSubviews)
    for button in buttons {
        let bottom = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.maxY), to: accessory)
        #expect(bottom.y == 36)
        #expect(accessory.hitTest(CGPoint(x: bottom.x, y: 43.5), with: nil) === button)
    }
}

@MainActor
@Test func keyRowTakesTheTerminalWindowsSizeClassBeforeTheKeyboardShowsIt() throws {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 750, height: 300))
    let window = try #require(mountTestView(view) as? UIWindow)
    defer { withExtendedLifetime(window) {} }
    view.display(Terminal(size: .init(columns: 60, rows: 4)))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    view.layoutIfNeeded()
    let row = try #require(view.phoneInput.inputAccessoryView as? TerminalKeyAccessory)
    #expect(row.window == nil && row.intrinsicContentSize.height == 60)

    // The window turns to landscape and focus arrives before the input's next layout.
    window.traitOverrides.verticalSizeClass = .compact
    try #require(view.focusInput())
    #expect(row.intrinsicContentSize.height == 44)
}

@MainActor
@Test func hideKeyboardResignsTheTerminalAndDisarmsControl() throws {
    let view = TerminalView(frame: .init(x: 0, y: 0, width: 402, height: 420))
    let window = try #require(mountTestView(view) as? UIWindow)
    defer { withExtendedLifetime(window) {} }
    view.display(Terminal(size: .init(columns: 28, rows: 4)))
    window.makeKeyAndVisible()
    view.layoutIfNeeded()
    try #require(view.focusInput())
    let row = try #require(view.phoneInput.inputAccessoryView as? TerminalKeyAccessory)
    let buttons = try #require(accessoryStack(row)?.arrangedSubviews.compactMap { $0 as? UIButton })
    try #require(buttons.first { $0.accessibilityLabel == "Control" }).sendActions(for: .touchUpInside)
    try #require(buttons.last { $0.accessibilityLabel == "Hide Keyboard" }).sendActions(for: .touchUpInside)
    #expect(!view.phoneInput.isFirstResponder && !row.controlArmed)
}

@MainActor
@Test func hidingTheKeyRowRemovesItsAccessoryAndDisarmsControl() throws {
    let view = TerminalView(frame: .zero)
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let row = try #require(view.phoneInput.inputAccessoryView as? TerminalKeyAccessory)
    let buttons = accessoryStack(row)?.arrangedSubviews.compactMap { $0 as? UIButton }
    try #require(buttons?.first { $0.accessibilityLabel == "Control" }).sendActions(for: .touchUpInside)
    #expect(row.controlArmed)
    view.showsKeyRow = false
    #expect(view.phoneInput.inputAccessoryView == nil && !row.controlArmed)
    view.showsKeyRow = true
    #expect(view.phoneInput.inputAccessoryView === row)
}

@MainActor
@Test func aDisplacedPhoneShellKeepsSelectionAndRejectsNewInput() throws {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let window = UIWindow(frame: view.bounds)
    window.addSubview(view)
    defer { withExtendedLifetime(window) {} }
    var term = Terminal(size: .init(columns: 40, rows: 20))
    _ = term.receive("Final output.".utf8)
    view.display(term)
    let selected = TerminalView.Selection(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 12)
    view.selection = selected
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(term.encode($0)) }
    let input = view.phoneInput
    input.setMarkedText("つばさ", selectedRange: .init(location: 3, length: 0))
    view.setInputAvailability(.blocked, dismissKeyboard: true)
    #expect(!input.canBecomeFirstResponder)
    #expect(input.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
    input.insertText("ignored")
    input.setMarkedText("鳥", selectedRange: .init(location: 1, length: 0))
    input.unmarkText()
    input.deleteBackward()
    input.pasteText("old paste")
    #expect(input.markedTextRange == nil && input.text.isEmpty)
    #expect(view.selection == selected && view.selectedText == "Final output.")
    #expect(sent.isEmpty)
    view.setInputAvailability(.live, dismissKeyboard: false)
    input.insertText("w")
    #expect(sent == [[119]])
}

@MainActor private func accessoryStack(_ view: UIView) -> UIStackView? {
    view as? UIStackView ?? view.subviews.lazy.compactMap(accessoryStack).first
}
#endif
