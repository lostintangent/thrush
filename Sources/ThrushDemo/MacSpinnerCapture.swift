#if os(macOS)
import AppKit
import ThrushUI

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
        let notice: VisiblePaneNotice?
        let spinnerFrame: CGRect?
    }

    static func startIfRequested(session: DemoSession, window: NSWindow) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--spinner-capture-state"), index + 2 < args.count,
              session.options.scene.capturesNotice else { return }
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
                if let screen = window.screen, let root = window.contentView {
                    let indicator = spinner(in: root)
                    let frame = indicator.map {
                        let rect = $0.convert($0.bounds, to: nil)
                        return CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
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
                                      scale: window.backingScaleFactor, notice: session.view.visiblePaneNotice, spinnerFrame: frame)
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

    private static func spinner(in view: NSView) -> NSView? {
        guard !view.isHidden, view.alphaValue > 0 else { return nil }
        if let progress = view as? NSProgressIndicator, progress.style == .spinning { return progress }
        for child in view.subviews {
            if let progress = spinner(in: child) { return progress }
        }
        return nil
    }
}
#endif
