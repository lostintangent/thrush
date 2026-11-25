#if os(macOS)
import AppKit

@MainActor final class CursorSpinner: NSProgressIndicator {
    private(set) var animates = false

    init() {
        super.init(frame: .zero)
        style = .spinning
        controlSize = .small
        isIndeterminate = true
        isDisplayedWhenStopped = true
        setAccessibilityElement(true)
        setAccessibilityIdentifier("terminal.cursorSpinner")
        setAccessibilityLabel("Connecting")
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func place(in frame: CGRect) {
        if self.frame != frame {
            self.frame = frame
            bounds.size = NSSize(width: 16, height: 16)
        }
    }

    func setAnimating(_ animating: Bool) {
        guard animates != animating else { return }
        animates = animating
        if animating { startAnimation(nil) } else { stopAnimation(nil) }
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
        accessibilityLabel = "Connecting"
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
