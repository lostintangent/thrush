#if os(macOS)
import AppKit

/// Fixed cursor-colored spokes keep their contrast when AppKit makes the window inactive.
@MainActor final class CursorSpinner: NSView {
    private let spokes = (0..<8).map { _ in CAShapeLayer() }
    private let trail: [Float] = [1, 0.92, 0.82, 0.70, 0.57, 0.45, 0.34, 0.24]
    private(set) var animates = false
    var ink: CGColor? {
        didSet {
            guard ink != oldValue else { return }
            for spoke in spokes { spoke.strokeColor = ink }
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for (index, spoke) in spokes.enumerated() {
            spoke.lineCap = .round
            spoke.opacity = trail[index]
            spoke.actions = ["strokeColor": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
            layer?.addSublayer(spoke)
        }
        setAccessibilityRole(.busyIndicator)
        setAccessibilityElement(true)
        setAccessibilityIdentifier("terminal.cursorSpinner")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(in frame: CGRect) {
        guard frame != self.frame else { return }
        let sizeChanged = frame.size != self.frame.size
        self.frame = frame
        guard sizeChanged else { return }
        let side = min(frame.width, frame.height)
        for (index, spoke) in spokes.enumerated() {
            let angle = -CGFloat(index) * .pi / 4
            func point(_ radius: CGFloat) -> CGPoint {
                CGPoint(x: bounds.midX + side * radius * sin(angle), y: bounds.midY + side * radius * cos(angle))
            }
            let path = CGMutablePath()
            path.move(to: point(0.23))
            path.addLine(to: point(0.39))
            spoke.path = path
            spoke.lineWidth = side * 0.18
        }
    }

    func setAnimating(_ animating: Bool) {
        guard animates != animating else { return }
        animates = animating
        for (index, spoke) in spokes.enumerated() {
            if animating {
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = (0..<spokes.count).map { trail[(index + $0) % spokes.count] }
                pulse.calculationMode = .discrete
                pulse.duration = 0.8
                pulse.repeatCount = .infinity
                spoke.add(pulse, forKey: "pulse")
            } else {
                spoke.removeAnimation(forKey: "pulse")
            }
        }
    }
}
#else
import UIKit

@MainActor final class CursorSpinner: UIActivityIndicatorView {
    init() {
        super.init(style: .medium)
        hidesWhenStopped = false
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "terminal.cursorSpinner"
    }

    required init(coder: NSCoder) { super.init(coder: coder) }

    func place(in frame: CGRect) {
        let scale = frame.width / bounds.width
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if self.transform != transform { self.transform = transform }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if self.center != center { self.center = center }
    }

    func setAnimating(_ animating: Bool) {
        guard isAnimating != animating else { return }
        if animating { startAnimating() } else { stopAnimating() }
    }
}
#endif
