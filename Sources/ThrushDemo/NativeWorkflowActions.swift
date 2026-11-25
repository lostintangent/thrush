import Thrush
import ThrushReplay
import ThrushUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Perform the recorded actions through the responders and geometry of the packaged pane.
@MainActor
enum NativeWorkflowActions {
    private typealias Failure = RenderBenchmark.Failure

    static func input(_ input: Terminal.Input, view: TerminalView) throws {
        #if os(iOS)
        _ = try phoneInput(view)
        #endif
        let probe = try NativeInteractionProbe(view: view)
        switch input {
        case .text(let text):
            // The PTY records commands and their Return together. Route the terminator
            // through the keyboard, exactly as when the native input method commits a line.
            for (index, part) in text.split(separator: "\r", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { try key(.enter, modifiers: [], view: view) }
                if !part.isEmpty { try probe.commit(String(part)) }
            }
        case .paste(let text):
            try probe.paste(text)
        case .key(let key, let modifiers):
            try self.key(key, modifiers: modifiers, view: view)
        default:
            throw Failure("The recorded workflow requested an unsupported native input.")
        }
    }

    static func verifyKeyboardDown(_ view: TerminalView) async throws {
        #if os(iOS)
        guard let root = view.window?.rootViewController?.viewIfLoaded,
              let input = view.subviews.compactMap({ $0 as? UITextView }).first else {
            throw Failure("Missing the terminal's native iPhone keyboard.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !input.isFirstResponder {
            if input.inputAccessoryView?.window == nil,
               root.keyboardLayoutGuide.layoutFrame.height <= root.safeAreaInsets.bottom + 1 { return }
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure("The terminal must leave the keyboard down until the user focuses it.")
        #endif
    }

    static func focusForTyping(_ view: TerminalView) async throws {
        #if os(iOS)
        try await verifyKeyboardDown(view)
        let probe = try NativeInteractionProbe(view: view)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !probe.activateTyping() {
            guard ContinuousClock.now < deadline else { throw Failure("The transcript has no enabled Type in terminal action.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await settleKeyboard(view: view, landscape: nil)
        #else
        guard view.focusInput() else { throw Failure("The Mac terminal could not take input focus.") }
        #endif
    }

    static func copy(_ copy: ReplayFixture.Copy, view: TerminalView) throws -> String {
        // Recorded row/column endpoints belong to the recording grid. The accessible
        // logical line identifies the same user-visible selection after native reflow.
        let probe = try NativeInteractionProbe(view: view)
        let fullText = probe.transcript
        let source = fullText as NSString
        let range = source.range(of: copy.text, options: .literal)
        guard range.location != NSNotFound else { throw Failure("The recorded copy text is missing from the native transcript.") }
        let remainder = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
        guard source.range(of: copy.text, options: .literal, range: remainder).location == NSNotFound else {
            throw Failure("The native transcript contains multiple matches for the requested selection.")
        }
        try probe.select(range, in: fullText)
        guard let selection = view.selection, let snapshot = view.snapshot else {
            throw Failure("The native pane did not retain its compiler-path selection.")
        }
        let top = snapshot.history.count - view.historyOffset
        let endRow = copy.end.column == 0 ? copy.end.row - 1 : copy.end.row
        let endColumn = copy.end.column == 0 ? snapshot.size.columns - 1 : copy.end.column - 1
        guard selection.anchorRow != selection.headRow,
              selection.anchorRow + top == copy.start.row, selection.anchorColumn == copy.start.column,
              selection.headRow + top == endRow, selection.headColumn == endColumn else {
            throw Failure("The selected native cells differ from xterm's soft-wrapped range.")
        }
        #if os(macOS)
        let result = probe.selection // Cocoa Copy reads the native selection into a private pasteboard.
        #else
        let responder = try phoneInput(view)
        guard responder.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil) else {
            throw Failure("UIKit Copy is unavailable for the wrapped selection.")
        }
        responder.copy(nil)
        let result = UIPasteboard.general.string
        #endif
        guard let result, result.utf8.elementsEqual(copy.text.utf8) else {
            throw Failure("Native Copy did not preserve the recorded UTF-8 text.")
        }
        return result
    }

    #if os(macOS)
    private static func key(_ key: Terminal.Input.Key, modifiers: Terminal.Input.Modifiers, view: TerminalView) throws {
        guard let window = view.window, view.focusInput(), let responder = window.firstResponder else {
            throw Failure("The terminal keyboard responder is unavailable.")
        }
        let code: UInt16
        let characters: String
        switch key {
        case .enter: (code, characters) = (36, "\r")
        case .backspace: (code, characters) = (51, "\u{7f}")
        case .escape: (code, characters) = (53, "\u{1b}")
        case .pageUp: (code, characters) = (116, "\u{f72c}")
        case .pageDown: (code, characters) = (121, "\u{f72d}")
        case .character("t"): (code, characters) = (17, "t")
        default: throw Failure("Unrecognized recorded AppKit key: \(key).")
        }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else {
            throw Failure("AppKit could not create the recorded key event.")
        }
        responder.keyDown(with: event)
    }

    static func resize(_ requested: Terminal.Size, view: TerminalView, landscape: Bool = false) async throws {
        guard let window = view.window, let content = window.contentView else { throw Failure("Missing native window.") }
        for _ in 0..<8 {
            content.layoutSubtreeIfNeeded()
            guard let grid = view.gridSize else { throw Failure("The native window has no grid.") }
            if grid == requested { return }
            let client = window.firstResponder as? any NSTextInputClient
            let cell = client?.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil).size ?? .zero
            // AppKit reports the renderer's snapped caret rectangle to input methods. Before
            // the first frame it can be empty, so make the first adjustment using the pane.
            let width = cell.width > 0 ? cell.width : view.bounds.width / CGFloat(grid.columns)
            let height = cell.height > 0 ? cell.height : view.bounds.height / CGFloat(grid.rows)
            window.setContentSize(NSSize(width: content.bounds.width + CGFloat(requested.columns - grid.columns) * width,
                                         height: content.bounds.height + CGFloat(requested.rows - grid.rows) * height))
            await Task.yield()
        }
        throw Failure("The Mac pane did not reach the requested \(requested.columns)×\(requested.rows) grid.")
    }
    #else
    private static func phoneInput(_ view: TerminalView) throws -> UITextView {
        guard let input = view.subviews.compactMap({ $0 as? UITextView }).first, input.isFirstResponder else {
            throw Failure("The terminal's native iPhone keyboard is not focused.")
        }
        return input
    }

    private static func key(_ key: Terminal.Input.Key, modifiers: Terminal.Input.Modifiers, view: TerminalView) throws {
        let responder = try phoneInput(view)
        let value: String
        switch key {
        case .enter where modifiers.isEmpty: responder.insertText("\n"); return
        case .backspace where modifiers.isEmpty: responder.deleteBackward(); return
        case .escape: value = UIKeyCommand.inputEscape
        case .pageUp: value = UIKeyCommand.inputPageUp
        case .pageDown: value = UIKeyCommand.inputPageDown
        case .character(let character): value = String(character)
        default: throw Failure("Unrecognized recorded UIKit key: \(key).")
        }
        var flags: UIKeyModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.alt) { flags.insert(.alternate) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        guard let command = responder.keyCommands?.first(where: { $0.input == value && $0.modifierFlags == flags }),
              let action = command.action, responder.canPerformAction(action, withSender: command),
              UIApplication.shared.sendAction(action, to: responder, from: command, for: nil) else {
            throw Failure("The focused UIKit responder could not perform the recorded keyboard command \(key).")
        }
    }

    static func resize(_ requested: Terminal.Size, view: TerminalView, landscape: Bool = false) async throws {
        try await settleKeyboard(view: view, landscape: landscape)
    }

    private static func settleKeyboard(view: TerminalView, landscape: Bool?) async throws {
        guard let window = view.window, let scene = window.windowScene, let host = window.rootViewController else {
            throw Failure("The terminal is missing its native iPhone window scene.")
        }
        // The driver knows which operation is a rotation even when a different source grid
        // records the same workflow. UIKit supplies the actual safe areas and keyboard size.
        func requestedOrientation() -> Bool {
            guard let landscape else { return true }
            let orientation = scene.effectiveGeometry.interfaceOrientation
            return landscape ? orientation.isLandscape : orientation.isPortrait
        }
        var rejected: Error?
        if let landscape, !requestedOrientation() {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeLeft : .portrait)) { rejected = $0 }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        var previousGrid: Terminal.Size?
        var previousKeyboard = CGRect.null
        var unchangedSince = clock.now
        while clock.now < deadline {
            if let rejected { throw rejected }
            host.view.layoutIfNeeded()
            let keyboard = host.view.keyboardLayoutGuide.layoutFrame
            let responder = view.subviews.compactMap { $0 as? UITextView }.first
            let accessory = responder?.inputAccessoryView?.bounds.height ?? 0
            let grid = view.gridSize
            if grid != previousGrid || keyboard != previousKeyboard || !requestedOrientation() ||
                host.transitionCoordinator != nil || responder?.isFirstResponder != true ||
                responder?.inputAccessoryView?.window == nil || abs(accessory - 44) > 0.5 ||
                keyboard.height <= host.view.safeAreaInsets.bottom + accessory + 1 {
                unchangedSince = clock.now
            } else if grid != nil, clock.now - unchangedSince >= .milliseconds(300) {
                guard responder?.textInputMode?.primaryLanguage?.hasPrefix("en") == true else {
                    throw Failure("The simulator workflow requires the English software keyboard.")
                }
                return
            }
            previousGrid = grid
            previousKeyboard = keyboard
            try await Task.sleep(for: .milliseconds(40))
        }
        throw Failure("The iPhone pane did not settle with its software keyboard in the requested orientation.")
    }
    #endif
}
