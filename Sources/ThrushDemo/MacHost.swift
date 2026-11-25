#if os(macOS)
import AppKit
import SwiftUI
import Thrush
import ThrushUI

@main
@MainActor
enum ThrushMac {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class MacHost: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let session = DemoSession(options: DemoOptions())
    private var window: NSWindow!
    private var activeAppearance: DemoOptions.Appearance = .system

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cycle = session.options.cyclesAppearance
        setAppearance(cycle || session.options.customTheme ? .dark : session.options.appearance)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 454),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Thrush"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 180)
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        let host = NSHostingView(rootView: DemoSurface(session: session))
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(NSRect(x: 0, y: 0, width: 720, height: 486), display: false)
        window.center()

        session.onThemeChange = { [weak self] in self?.applyChrome($0) }
        session.onBenchmarkFinished = { success in
            if !success { exit(EXIT_FAILURE) }
            NSApp.terminate(nil)
        }
        applyChrome(session.view.resolvedTheme)
        makeMenus()
        if cycle { session.onFirstOutput = { [weak self] in self?.cycleAppearance() } }
        session.onFirstUsable = { [weak self] in self?.session.view.focusInput() }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        if session.options.benchmarkURL != nil { session.view.focusInput() }
        NSApp.activate()
        session.setActive(true)
        MacSpinnerCapture.startIfRequested(session: session, window: window)
        MacWindowLifecycleCheck.startIfRequested(session: session, window: window)
    }

    // The renderer benchmark mounts its Metal view directly. Connected panes observe
    // window visibility themselves and keep their shells attached while hidden.
    func applicationWillHide(_ notification: Notification) {
        if session.options.benchmarkURL != nil { session.view.setRenderingActive(false) }
    }

    func applicationDidUnhide(_ notification: Notification) {
        if session.options.benchmarkURL != nil { session.view.setRenderingActive(true) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowWillClose(_ notification: Notification) { session.setActive(false) }

    private func applyChrome(_ theme: TerminalTheme) {
        let rgb = theme.hostBacking
        window.backgroundColor = NSColor(srgbRed: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255,
                                        blue: CGFloat(rgb.blue) / 255, alpha: 1)
    }

    private func makeMenus() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        let app = submenu("Thrush")
        app.addItem(withTitle: "Hide Thrush", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h").target = NSApp
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Thrush", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = submenu("Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        let replay = submenu("Replay")
        let titles: [(DemoOptions.Scene, String)] = [
            (.shell, "Build"), (.editor, "Swift in Vim"), (.log, "Recorded Compiler Log"),
            (.vim, "Recorded Vim Edit"), (.prompt, "Shell Prompt"), (.glyphs, "Wide Glyphs"),
        ]
        for (index, pair) in titles.enumerated() {
            let item = replay.addItem(withTitle: pair.1, action: #selector(selectScene(_:)), keyEquivalent: String(index + 1))
            item.representedObject = pair.0.rawValue
            item.target = self
        }

        let appearance = submenu("Appearance")
        for name in ["System", "Light", "Dark", "Custom"] {
            let item = appearance.addItem(withTitle: name, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
        }
        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    /// Exercise exactly the same actions as the Appearance menu while keeping the live
    /// terminal attached. The capture runner listens for these phase boundaries on stdout.
    private func cycleAppearance() {
        Task {
            guard let menu = NSApp.mainMenu?.item(withTitle: "Appearance")?.submenu else { return }
            for title in ["Dark", "Light", "Custom"] {
                if title != "Dark" { try? await Task.sleep(for: .seconds(4)) }
                let index = menu.indexOfItem(withTitle: title)
                guard index >= 0 else { return }
                menu.performActionForItem(at: index)
                FileHandle.standardOutput.write(Data("appearance=\(title.lowercased())\n".utf8))
            }
        }
    }

    @objc private func selectScene(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let scene = DemoOptions.Scene(rawValue: name) {
            session.replay(scene)
        }
    }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        if sender.title == "Custom" {
            setAppearance(.dark)
            session.theme = DemoSession.customTheme
        } else if let appearance = DemoOptions.Appearance(rawValue: sender.title.lowercased()) {
            session.theme = nil
            setAppearance(appearance)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectScene(_:)) {
            item.state = (item.representedObject as? String) == session.options.scene.rawValue ? .on : .off
        } else if item.action == #selector(changeAppearance(_:)) {
            let name = session.theme == nil ? activeAppearance.rawValue : "custom"
            item.state = item.title.lowercased() == name ? .on : .off
        }
        return true
    }

    private func setAppearance(_ appearance: DemoOptions.Appearance) {
        activeAppearance = appearance
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
#endif
