#if os(macOS)
import AppKit
import Thrush

/// Opt-in observation of the actual AppKit window while the hosted screenshot driver changes focus.
@MainActor enum MacSpinnerCapture {
    private struct State: Encodable, Equatable {
        let pid: Int32
        let windowID: Int
        let scene, appearance: String
        let keyWindow, activeApp, visible, hasTranscript, reduceMotion: Bool
        let frontmostPID, helperPID: Int32?
        let helperError: String?
        let windowFrame, screenVisibleFrame: CGRect
        let scale: CGFloat
        let spinnerFrame, cursorCellFrame, firstCellFrame, lastCellFrame: CGRect?
        let cursorSpinnerLabel: String?
        let shellEnded: Bool
        let newShellButtonFrame: CGRect?
        let gridFrame: CGRect
        let columns, rows: Int
    }

    static func startIfRequested(session: DemoSession, window: NSWindow) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--spinner-capture-state"), index + 2 < args.count,
              session.options.scene.capturesSessionState else { return }
        let path = URL(fileURLWithPath: args[index + 1])
        let helperURL = URL(fileURLWithPath: args[index + 2])
        guard Bundle(url: helperURL)?.bundleIdentifier == "app.thrush.lifecycle-cover" else { return }
        Task { @MainActor [weak session, weak window] in
            var written: State?
            var helper: NSRunningApplication?
            var helperError: String?
            let request = path.appendingPathExtension("focus")
            while let session, let window, !Task.isCancelled {
                if helper == nil, helperError == nil, FileManager.default.fileExists(atPath: request.path) {
                    do {
                        let rect = try JSONDecoder().decode([Double].self, from: Data(contentsOf: request))
                        guard rect.count == 4 else { return }
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        config.createsNewApplicationInstance = true
                        config.arguments = rect.map { String($0) } + ["--capture-geometry", path.appendingPathExtension("helper-frame").path]
                        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "app.thrush.lifecycle-cover")
                        helper = try await NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
                    } catch {
                        helperError = error.localizedDescription
                    }
                }
                if let screen = window.screen, let grid = session.view.gridSize {
                    let rect = session.view.convert(session.view.bounds, to: nil)
                    let gridFrame = CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
                    let button = window.toolbar?.visibleItems?.first { $0.itemIdentifier.rawValue == "demo.newShell" }?.view as? NSButton
                    var buttonFrame: CGRect?
                    if let button, button.window === window, button.isEnabled, !button.isHiddenOrHasHiddenAncestor,
                       !button.isDescendant(of: session.view), button.title == "New Shell" {
                        let rect = button.convert(button.bounds, to: nil)
                        buttonFrame = CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
                    }
                    let press = path.appendingPathExtension("new-shell")
                    if session.options.scene == .ended, buttonFrame != nil, FileManager.default.fileExists(atPath: press.path) {
                        do {
                            try FileManager.default.removeItem(at: press)
                            button?.performClick(nil)
                            continue
                        } catch { return }
                    }
                    let spinner = session.view.subviews.first {
                        $0.accessibilityRole() == .busyIndicator && !$0.isHiddenOrHasHiddenAncestor && $0.isAccessibilityElement()
                            && $0.accessibilityIdentifier() == "terminal.cursorSpinner"
                    }
                    let state = State(pid: ProcessInfo.processInfo.processIdentifier, windowID: window.windowNumber,
                                      scene: session.options.scene.rawValue,
                                      appearance: session.view.resolvedTheme == .slateDark ? "dark" : "light",
                                      keyWindow: window.isKeyWindow, activeApp: NSApp.isActive,
                                      visible: window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible),
                                      hasTranscript: session.view.snapshot?.rows.contains { $0.text == "Test run passed." } ?? false,
                                      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                                      frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                      helperPID: helper?.processIdentifier, helperError: helperError,
                                      windowFrame: window.frame, screenVisibleFrame: screen.visibleFrame,
                                      scale: window.backingScaleFactor, spinnerFrame: session.view.cursorSpinnerFrameInWindow,
                                      cursorCellFrame: session.view.cursorCellFrameInWindow, firstCellFrame: session.view.cellFrameInWindow(row: 0, column: 0),
                                      lastCellFrame: session.view.cellFrameInWindow(row: grid.rows - 1, column: grid.columns - 1),
                                      cursorSpinnerLabel: spinner?.accessibilityLabel(),
                                      shellEnded: session.terminalSession?.hasEnded == true, newShellButtonFrame: buttonFrame,
                                      gridFrame: gridFrame,
                                      columns: grid.columns, rows: grid.rows)
                    if written != state {
                        do {
                            try JSONEncoder().encode(state).write(to: path, options: .atomic)
                            written = state
                        } catch {
                            FileHandle.standardError.write(Data("Could not write Mac spinner capture state: \(error)\n".utf8))
                            return
                        }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

}
#endif
