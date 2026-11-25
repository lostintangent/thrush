import CoreGraphics
import Thrush
import ThrushUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Geometry accompanies the same Metal submission checked by the driver. Coordinates
/// use the top-left of the captured window on both platforms and include the Mac title bar.
@MainActor
struct WorkflowCapture: Encodable {
    struct Layout {
        let windowSize: [CGFloat]
        let gridInWindow: [CGFloat]

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
            #else
            let position = view.convert(grid, to: window)
            windowSize = [window.bounds.width, window.bounds.height]
            gridInWindow = [position.minX, position.minY, position.width, position.height]
            #endif
        }
    }

    let name: String
    let eventIndex, columns, rows: Int
    let appearance: String
    let windowSize, gridInWindow: [CGFloat]
    let inkMask: [String]
    let selection: [Int]?
    let copiedText: String?

    init(name: String, eventIndex: Int, view: TerminalView, snapshot: Terminal.Snapshot, layout: Layout, copied: String?) {
        self.name = name
        self.eventIndex = eventIndex
        columns = snapshot.size.columns
        rows = snapshot.size.rows
        appearance = view.resolvedTheme == .slateLight ? "light" : "dark"
        windowSize = layout.windowSize
        gridInWindow = layout.gridInWindow
        selection = view.selection.map { [$0.anchorRow, $0.anchorColumn, $0.headRow, $0.headColumn] }
        copiedText = copied
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
}
