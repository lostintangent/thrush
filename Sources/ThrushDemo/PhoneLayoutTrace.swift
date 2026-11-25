#if os(iOS)
import ThrushUI
import UIKit

/// Captures the UIKit animation context synchronously with geometry changes in the demo.
@MainActor final class PhoneLayoutTrace: NSObject {
    private struct Layout: Encodable, Equatable {
        let windowSize, terminalSize: CGSize
        let keyboardGuideInWindow: CGRect
        let orientation, appearance: String
        let columns, rows: Int?
        let inheritedAnimationDuration: TimeInterval
        let transitionCoordinatorDuration: TimeInterval?
    }

    private struct Event: Encodable {
        let time: TimeInterval
        let source: String
        let layout: Layout?
        let keyboardEndFrameInScreen: CGRect?
        let keyboardAnimationDuration: TimeInterval?
        var afterNotificationAt: TimeInterval? = nil
    }

    private weak var terminal: TerminalView?
    private weak var host: UIViewController?
    private var boundsObservation: NSKeyValueObservation?
    private var previous: Layout?
    private let output: FileHandle

    init?(terminal: TerminalView, host: UIViewController) {
        guard CommandLine.arguments.contains("--trace-rotation-layout") else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let url = URL.documentsDirectory.appending(path: "rotation-layout-\(pid).jsonl")
        do {
            try Data().write(to: url)
            output = try FileHandle(forWritingTo: url)
        } catch {
            FileHandle.standardError.write(Data("Could not create layout trace: \(error)\n".utf8))
            return nil
        }
        self.terminal = terminal
        self.host = host
        super.init()
        // A terminal-only resize can occur between host layout passes. Observe its model
        // layer on the same UIKit call stack, before the inherited animation context ends.
        boundsObservation = terminal.layer.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.recordLayout("terminal.bounds") }
        }
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
    }

    func recordLayout(_ source: String) {
        guard let layout, layout != previous else { return }
        previous = layout
        write(Event(time: Date.now.timeIntervalSince1970, source: source, layout: layout,
                    keyboardEndFrameInScreen: nil, keyboardAnimationDuration: nil))
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        let info = notification.userInfo
        let frame = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
        let time = Date.now.timeIntervalSince1970
        write(Event(time: time, source: notification.name.rawValue, layout: layout,
                    keyboardEndFrameInScreen: frame, keyboardAnimationDuration: duration))
        // All observers have received the notification by the next turn of the main queue.
        // Keep this sample separate from the synchronous report to avoid observer-order assumptions.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            write(Event(time: Date.now.timeIntervalSince1970, source: "keyboard.delivered", layout: layout,
                        keyboardEndFrameInScreen: frame, keyboardAnimationDuration: duration, afterNotificationAt: time))
        }
    }

    private var layout: Layout? {
        guard let terminal, let host, let root = host.viewIfLoaded, let window = root.window,
              let scene = window.windowScene else { return nil }
        let orientation: String = switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        default: "unknown"
        }
        return Layout(windowSize: window.bounds.size, terminalSize: terminal.bounds.size,
                      keyboardGuideInWindow: root.convert(root.keyboardLayoutGuide.layoutFrame, to: window),
                      orientation: orientation, appearance: terminal.traitCollection.userInterfaceStyle == .dark ? "dark" : "light",
                      columns: terminal.gridSize?.columns, rows: terminal.gridSize?.rows,
                      inheritedAnimationDuration: UIView.inheritedAnimationDuration,
                      transitionCoordinatorDuration: host.transitionCoordinator?.transitionDuration)
    }

    private func write(_ event: Event) {
        do {
            var data = try JSONEncoder().encode(event)
            data.append(10)
            try output.write(contentsOf: data)
        } catch {
            FileHandle.standardError.write(Data("Could not record layout trace: \(error)\n".utf8))
        }
    }
}
#endif
