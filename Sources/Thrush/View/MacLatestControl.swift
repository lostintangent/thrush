#if os(macOS)
import AppKit
import ThrushCore

/// A 36 pt native capsule inside a 44 pt pointer target. Inactive windows and Reduce
/// Transparency use the Slate fallback so an available action remains legible.
final class MacLatestControl: NSView {
    var onActivate: (() -> Void)?
    private let button = LatestButton(title: "Latest", target: nil, action: nil)
    private var theme = TerminalTheme.slateDark
    private var trackingEdge = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 104, height: 44))
        button.frame = bounds.insetBy(dx: 0, dy: 4)
        button.autoresizingMask = [.width, .height]
        button.target = self
        button.action = #selector(activate)
        button.bezelStyle = .glass
        button.borderShape = .capsule
        button.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("Return to latest output")
        button.setAccessibilityIdentifier("terminal.latest")
        addSubview(button)
        for note in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateMaterial), name: note, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(updateMaterial),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateMaterial()
    }

    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateMaterial() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(_ theme: TerminalTheme) {
        guard self.theme != theme else { return }
        self.theme = theme
        updateMaterial()
    }

    @objc private func updateMaterial() {
        let inactive = window?.isKeyWindow != true || !NSApp.isActive
        let opaque = inactive || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let next = opaque ? theme : nil
        guard button.fallback != next else { return }
        button.fallback = next
        button.isBordered = !opaque
        button.needsDisplay = true
    }

    @objc private func activate() { onActivate?() }

    // AppKit tracks clicks on the visible button. Its four-point margins track the same action.
    override func mouseDown(with event: NSEvent) { trackingEdge = true; button.highlight(true) }
    override func mouseDragged(with event: NSEvent) {
        if trackingEdge { button.highlight(bounds.contains(convert(event.locationInWindow, from: nil))) }
    }
    override func mouseUp(with event: NSEvent) {
        guard trackingEdge else { return }
        trackingEdge = false
        button.highlight(false)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }
}

private final class LatestButton: NSButton {
    var fallback: TerminalTheme?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme = fallback else { super.draw(dirtyRect); return }
        func color(_ value: Terminal.RGB) -> NSColor {
            NSColor(srgbRed: CGFloat(value.red) / 255, green: CGFloat(value.green) / 255,
                    blue: CGFloat(value.blue) / 255, alpha: 1)
        }
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        color(isHighlighted ? theme.selection : theme.hostBacking).setFill()
        capsule.fill()
        color(theme.palette.ansi[8]).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        let ink = color(isHighlighted ? theme.selectionInk : theme.palette.foreground)
        let label = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                                                                     .foregroundColor: ink])
        let labelSize = label.size()
        let symbolSize: CGFloat = 14, gap: CGFloat = 6
        let start = floor((bounds.width - symbolSize - gap - labelSize.width) / 2)
        let symbol = image?.withSymbolConfiguration(.init(paletteColors: [ink]))
        symbol?.draw(in: CGRect(x: start, y: floor(bounds.midY - symbolSize / 2), width: symbolSize, height: symbolSize),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        label.draw(at: CGPoint(x: start + symbolSize + gap, y: floor(bounds.midY - labelSize.height / 2)))
    }
}
#endif
