#if os(iOS)
import Testing
import ThrushCore
@testable import Thrush
import UIKit

@MainActor
@Test func phoneTextInputCommitsMarkedTextExactlyOnce() throws {
    let terminal = Terminal(size: .init(columns: 40, rows: 20))
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
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
@Test func phoneKeyRowAndHardwareKeysUseTerminalModes() throws {
    var terminal = Terminal(size: .init(columns: 40, rows: 20))
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let input = view.phoneInput
    var sent: [[UInt8]] = []
    view.onInput = { sent.append(terminal.encode($0)) }
    let keyRow = try #require(input.inputAccessoryView)
    let stack = try #require(buttonStack(keyRow))
    let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
    let control = try #require(buttons.first { $0.accessibilityLabel == "Control" })
    let arrow = try #require(buttons.first { $0.accessibilityLabel == "Up arrow" })
    #expect(buttons.count == 8)
    keyRow.frame = .init(x: 0, y: 0, width: 320, height: KeyRow.height(compact: false))
    keyRow.layoutIfNeeded()
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
    let view = TerminalMetalView(frame: .zero)
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
@Test func phoneKeyRowUsesOnlyTheKeyboardHostResizeAnimation() throws {
    let window = UIWindow(frame: .init(x: 0, y: 0, width: 874, height: 402))
    let host = UIView(frame: window.bounds)
    let keyRow = KeyRow(onKey: { _ in }, onHide: {})
    window.addSubview(host)
    host.addSubview(keyRow)
    window.isHidden = false
    defer { window.isHidden = true }

    keyRow.frame = .init(x: 0, y: 0, width: 750, height: keyRow.intrinsicContentSize.height)
    keyRow.layoutIfNeeded()
    let stack = try #require(buttonStack(keyRow))
    let buttons = stack.arrangedSubviews
    #expect(buttons.count == 8)
    CATransaction.flush()

    // UIKit gives the key row its destination bounds and animates the keyboard host.
    // Auto Layout still runs with the host's inherited animation context.
    UIView.animate(withDuration: 5, delay: 0, options: .curveLinear) {
        host.transform = .init(scaleX: 0.6, y: 1)
        UIView.performWithoutAnimation { keyRow.bounds.size.width = 402 }
        keyRow.layoutIfNeeded()
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
    let keyRow = KeyRow(onKey: { _ in }, onHide: {})
    window.addSubview(keyRow)
    window.isHidden = false
    defer { window.isHidden = true }
    keyRow.traitOverrides.verticalSizeClass = .compact
    keyRow.updateTraitsIfNeeded()
    #expect(keyRow.intrinsicContentSize.height == 44)
    keyRow.frame = .init(x: 0, y: 0, width: 750, height: 44)
    keyRow.layoutIfNeeded()

    let buttons = try #require(buttonStack(keyRow)?.arrangedSubviews)
    for button in buttons {
        let bottom = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.maxY), to: keyRow)
        #expect(bottom.y == 36)
        #expect(keyRow.hitTest(CGPoint(x: bottom.x, y: 43.5), with: nil) === button)
    }
}

@MainActor
@Test func keyRowTakesTheTerminalWindowsSizeClassBeforeTheKeyboardShowsIt() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 750, height: 300))
    let window = try #require(mountTestView(view) as? UIWindow)
    defer { withExtendedLifetime(window) {} }
    view.display(Terminal(size: .init(columns: 60, rows: 4)))
    window.traitOverrides.verticalSizeClass = .regular
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    window.updateTraitsIfNeeded()
    let row = try #require(view.phoneInput.inputAccessoryView as? KeyRow)
    #expect(row.window == nil && row.frame.height == 60 && row.intrinsicContentSize.height == 60)

    // The window turns to landscape before focus. UIKit first sizes a row that joins the keyboard
    // from its frame, so the detached row's frame has to shrink with it.
    window.traitOverrides.verticalSizeClass = .compact
    window.updateTraitsIfNeeded()
    #expect(row.window == nil && row.intrinsicContentSize.height == 44)
    #expect(row.frame.height == 44)
}

@MainActor
@Test func hideKeyboardResignsTheTerminalAndDisarmsControl() throws {
    let view = TerminalMetalView(frame: .init(x: 0, y: 0, width: 402, height: 420))
    let window = try #require(mountTestView(view) as? UIWindow)
    defer { withExtendedLifetime(window) {} }
    view.display(Terminal(size: .init(columns: 28, rows: 4)))
    window.makeKeyAndVisible()
    view.layoutIfNeeded()
    try #require(view.focusInput())
    let row = try #require(view.phoneInput.inputAccessoryView as? KeyRow)
    let buttons = try #require(buttonStack(row)?.arrangedSubviews.compactMap { $0 as? UIButton })
    try #require(buttons.first { $0.accessibilityLabel == "Control" }).sendActions(for: .touchUpInside)
    try #require(buttons.last { $0.accessibilityLabel == "Hide Keyboard" }).sendActions(for: .touchUpInside)
    #expect(!view.phoneInput.isFirstResponder && !row.controlArmed)
}

@MainActor
@Test func hidingTheKeyRowRemovesItsAccessoryAndDisarmsControl() throws {
    let view = TerminalMetalView(frame: .zero)
    let window = mountTestView(view)
    defer { withExtendedLifetime(window) {} }
    let row = try #require(view.phoneInput.inputAccessoryView as? KeyRow)
    let buttons = buttonStack(row)?.arrangedSubviews.compactMap { $0 as? UIButton }
    try #require(buttons?.first { $0.accessibilityLabel == "Control" }).sendActions(for: .touchUpInside)
    #expect(row.controlArmed)
    view.showsKeyRow = false
    #expect(view.phoneInput.inputAccessoryView == nil && !row.controlArmed)
    view.showsKeyRow = true
    #expect(view.phoneInput.inputAccessoryView === row)
}

@MainActor
@Test func aDisplacedPhoneShellKeepsSelectionAndRejectsNewInput() throws {
    let view = TerminalMetalView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
    let window = UIWindow(frame: view.bounds)
    window.addSubview(view)
    defer { withExtendedLifetime(window) {} }
    var term = Terminal(size: .init(columns: 40, rows: 20))
    _ = term.receive("Final output.".utf8)
    view.display(term)
    let selected = TerminalMetalView.Selection(anchorRow: 0, anchorColumn: 0, headRow: 0, headColumn: 12)
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

@MainActor private func buttonStack(_ view: UIView) -> UIStackView? {
    view as? UIStackView ?? view.subviews.lazy.compactMap(buttonStack).first
}
#endif
