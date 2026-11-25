#if os(iOS)
import Thrush
import UIKit

/// Captures the UIKit animation context synchronously with geometry changes in the demo.
@MainActor final class PhoneLayoutTrace: NSObject {
    private struct Layout: Encodable, Equatable {
        let windowSize, terminalSize: CGSize
        let keyboardGuideInWindow: CGRect
        let keyboardEndFrameInWindow, paneKeyboardGuideInWindow: CGRect?
        let orientation, appearance: String
        let columns, rows: Int?
        let inheritedAnimationDuration: TimeInterval
        let transitionCoordinatorDuration: TimeInterval?
    }

    private struct LayerGeometry: Encodable {
        let bounds: CGRect
        let cornersInWindow, cornersInLayerTree: [CGPoint]

        init(_ layer: CALayer, windowLayer: CALayer) {
            bounds = layer.bounds
            let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                           CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
            cornersInWindow = corners.map { layer.convert($0, to: windowLayer) }
            cornersInLayerTree = corners.map { layer.convert($0, to: nil) }
        }
    }

    private struct Geometry: Encodable {
        let model: LayerGeometry
        let presentation: LayerGeometry?
        let safeAreaInBounds: CGRect
        let modelFrameInFixedScreen: CGRect

        @MainActor init?(_ view: UIView?) {
            guard let view, let window = view as? UIWindow ?? view.window, let screen = window.windowScene?.screen else { return nil }
            model = LayerGeometry(view.layer, windowLayer: window.layer)
            if let layer = view.layer.presentation(), let windowLayer = window.layer.presentation() {
                presentation = LayerGeometry(layer, windowLayer: windowLayer)
            } else {
                presentation = nil
            }
            safeAreaInBounds = view.safeAreaLayoutGuide.layoutFrame
            modelFrameInFixedScreen = window.convert(view.convert(view.bounds, to: window), to: screen.fixedCoordinateSpace)
        }
    }

    private struct AccessorySample: Encodable {
        let displayTime: CFTimeInterval
        let receivingWindow, accessoryWindow, accessory, stack, rightButton: Geometry?
        let sharesReceivingWindow: Bool?
    }

    private struct Event: Encodable {
        let time: TimeInterval
        let source: String
        let layout: Layout?
        let keyboardEndFrameInScreen: CGRect?
        let keyboardAnimationDuration: TimeInterval?
        var afterNotificationAt: TimeInterval? = nil
        var accessorySample: AccessorySample?
    }

    private weak var terminal: TerminalView?
    private weak var host: UIViewController?
    private var boundsObservation: NSKeyValueObservation?
    private var previous: Layout?
    private var sampleUntil: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var keyboardEndFrameInScreen: CGRect?
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
        if let previous, previous.windowSize != layout.windowSize || previous.orientation != layout.orientation {
            sampleTransition(for: host?.transitionCoordinator?.transitionDuration ?? 0)
        }
        previous = layout
        write(Event(time: Date.now.timeIntervalSince1970, source: source, layout: layout,
                    keyboardEndFrameInScreen: nil, keyboardAnimationDuration: nil))
    }

    @objc private func keyboardChanged(_ notification: Notification) {
        let info = notification.userInfo
        let frame = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let duration = (info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
        let time = Date.now.timeIntervalSince1970
        keyboardEndFrameInScreen = frame
        sampleTransition(for: duration ?? 0)
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

    private func sampleTransition(for duration: TimeInterval) {
        sampleUntil = max(sampleUntil, CACurrentMediaTime() + max(duration, 0.5) + 0.25)
        guard link == nil else { return }
        let display = CADisplayLink(target: self, selector: #selector(sampleFrame(_:)))
        display.add(to: .main, forMode: .common)
        link = display
    }

    @objc private func sampleFrame(_ display: CADisplayLink) {
        let window = host?.viewIfLoaded?.window
        let input = terminal?.subviews.first(where: \.isFirstResponder)
        let accessory = input?.inputAccessoryView
        let stack = accessory?.subviews.compactMap { $0 as? UIStackView }.first
        let right = stack?.arrangedSubviews.first { $0.accessibilityLabel == "Right arrow" }
        let sample = AccessorySample(displayTime: display.timestamp, receivingWindow: Geometry(window),
                                     accessoryWindow: Geometry(accessory?.window), accessory: Geometry(accessory),
                                     stack: Geometry(stack), rightButton: Geometry(right),
                                     sharesReceivingWindow: accessory?.window.map { $0 === window })
        write(Event(time: Date.now.timeIntervalSince1970, source: "accessory.display", layout: layout,
                    keyboardEndFrameInScreen: keyboardEndFrameInScreen, keyboardAnimationDuration: nil,
                    accessorySample: sample))
        if CACurrentMediaTime() >= sampleUntil {
            display.invalidate()
            link = nil
        }
    }

    private func paneKeyboardGuide(in window: UIWindow?) -> CGRect? {
        guard let window else { return nil }
        var responder: UIResponder? = terminal
        while let current = responder {
            if let controller = current as? UIViewController, let pane = controller.viewIfLoaded {
                return pane.convert(pane.keyboardLayoutGuide.layoutFrame, to: window)
            }
            responder = current.next
        }
        return nil
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
                      keyboardEndFrameInWindow: keyboardEndFrameInScreen.map { window.convert($0, from: scene.screen.coordinateSpace) },
                      paneKeyboardGuideInWindow: paneKeyboardGuide(in: window),
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
