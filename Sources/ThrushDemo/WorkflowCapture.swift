import CoreGraphics
import Thrush

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Geometry accompanies the same Metal submission checked by the driver. Coordinates
/// use the top-left of the captured window on both platforms and include the Mac title bar.
@MainActor
struct WorkflowCapture: Encodable {
    struct Keyboard: Encodable {
        let windowPoints, gridFrame: CGRect
        let displayScale, keyboardHeight, accessoryHeight: CGFloat
        let keys: [CGRect]
        let orientation: String
    }

    struct Layout {
        let windowSize: [CGFloat]
        let gridInWindow: [CGFloat]
        let keyboard: Keyboard?

        @MainActor init?(view: TerminalView, drawableGrid: CGRect) {
            guard let window = view.window, !view.bounds.isEmpty, !drawableGrid.isEmpty,
                  view.drawableSize.width > 0, view.drawableSize.height > 0 else { return nil }
            let sx = view.bounds.width / view.drawableSize.width
            let sy = view.bounds.height / view.drawableSize.height
            let grid = drawableGrid.applying(.init(scaleX: sx, y: sy))
            #if os(macOS)
            let local = CGRect(x: grid.minX, y: view.isFlipped ? grid.minY : view.bounds.height - grid.maxY,
                               width: grid.width, height: grid.height)
            let position = view.convert(local, to: nil)
            let windowHeight = window.frame.height
            windowSize = [window.frame.width, windowHeight]
            gridInWindow = [position.minX, windowHeight - position.maxY, position.width, position.height]
            keyboard = nil
            #else
            guard let root = window.rootViewController?.viewIfLoaded, let scene = window.windowScene,
                  !root.bounds.isEmpty else { return nil }
            let position = view.convert(grid, to: window)
            windowSize = [window.bounds.width, window.bounds.height]
            gridInWindow = [position.minX, position.minY, position.width, position.height]
            let accessory = view.subviews.first(where: \.isFirstResponder)?.inputAccessoryView
            keyboard = Keyboard(windowPoints: root.bounds, gridFrame: view.convert(view.bounds, to: root),
                                displayScale: view.traitCollection.displayScale,
                                keyboardHeight: root.keyboardLayoutGuide.layoutFrame.height,
                                accessoryHeight: accessory?.window == nil ? 0 : accessory?.bounds.height ?? 0,
                                keys: PhoneCapture.keyFrames(of: accessory, in: root),
                                orientation: scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait")
            #endif
        }
    }

    let name: String
    let eventIndex, columns, rows: Int
    let appearance: String
    let windowSize, gridInWindow: [CGFloat]
    let keyboard: Keyboard?
    let ended: Bool
    let inkMask: [String]
    let selection: [Int]?
    let copiedText: String?
    /// Window rectangles of the pane's own controls over the grid, such as Latest while reading history.
    let overlays: [[CGFloat]]

    init(name: String, eventIndex: Int, view: TerminalView, snapshot: Terminal.Snapshot, layout: Layout, copied: String?, ended: Bool = false) {
        self.ended = ended
        self.name = name
        self.eventIndex = eventIndex
        columns = snapshot.size.columns
        rows = snapshot.size.rows
        appearance = view.resolvedTheme == .slateLight ? "light" : "dark"
        windowSize = layout.windowSize
        gridInWindow = layout.gridInWindow
        keyboard = layout.keyboard
        selection = view.selection.map { [$0.anchorRow, $0.anchorColumn, $0.headRow, $0.headColumn] }
        copiedText = copied
        overlays = Self.overlays(over: view)
        inkMask = snapshot.rows.map { row in
            var bytes = [UInt8](repeating: 48, count: snapshot.size.columns)
            for col in bytes.indices {
                let cell = row[col]
                if cell.width > 0, !cell.style.invisible, !cell.text.isEmpty, cell.text != " " {
                    bytes[col] = 49
                    if cell.width == 2, col + 1 < bytes.count { bytes[col + 1] = 49 }
                }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func overlays(over view: TerminalView) -> [[CGFloat]] {
        // Glass and its shadow extend a few points past the control's frame.
        let margin: CGFloat = 6
        #if os(macOS)
        guard let window = view.window, let root = window.contentView else { return [] }
        func controls(in view: NSView) -> [NSView] {
            (view.accessibilityIdentifier() == "terminal.latest" && !view.isHiddenOrHasHiddenAncestor ? [view] : [])
                + view.subviews.flatMap(controls)
        }
        return controls(in: root).map {
            let frame = $0.convert($0.bounds, to: nil)
            return [frame.minX - margin, window.frame.height - frame.maxY - margin, frame.width + 2 * margin, frame.height + 2 * margin]
        }
        #else
        guard let window = view.window else { return [] }
        func controls(in view: UIView) -> [UIView] {
            (view.accessibilityIdentifier == "terminal.latest"
                && sequence(first: view, next: \.superview).allSatisfy { !$0.isHidden && $0.alpha > 0 } ? [view] : [])
                + view.subviews.flatMap(controls)
        }
        return controls(in: window).map {
            let frame = $0.convert($0.bounds, to: window).insetBy(dx: -margin, dy: -margin)
            return [frame.minX, frame.minY, frame.width, frame.height]
        }
        #endif
    }
}
