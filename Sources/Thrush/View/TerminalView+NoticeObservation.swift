#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Mounted geometry in the pane container's native coordinate space.
package struct VisiblePaneNotice: Equatable, Encodable {
    package let title: String
    package let detail: String?
    package let action: String?
    package let actionLabel: String?
    package let frame: CGRect
    /// Top-left coordinates in the native window screenshot, including the Mac title bar.
    package let frameInWindow: CGRect
}

extension TerminalView {
    private var enclosingPane: TerminalPaneContainer? {
        var ancestor = superview
        while let item = ancestor {
            if let container = item as? TerminalPaneContainer { return container }
            ancestor = item.superview
        }
        return nil
    }

    #if os(iOS)
    package var paneGeometryInWindow: (frame: CGRect, safeArea: CGRect, firstCell: CGRect)? {
        guard let pane = enclosingPane, let window else { return nil }
        return (pane.convert(pane.bounds, to: window),
                pane.convert(pane.safeAreaLayoutGuide.layoutFrame, to: window),
                convert(cellRect(row: 0, column: 0), to: window))
    }
    #endif

    /// Used by the packaged capture and real-PTY probes after the native notice has appeared.
    package var visiblePaneNotice: VisiblePaneNotice? {
        guard let container = enclosingPane else { return nil }
        guard let notice = container.current, let content = container.mountedNoticeView,
              let window = content.window, !content.isHidden, content.bounds.width > 0,
              content.bounds.height > 0 else { return nil }
        #if os(macOS)
        let alpha = content.layer?.presentation().map { CGFloat($0.opacity) } ?? content.alphaValue
        #else
        let alpha = content.layer.presentation().map { CGFloat($0.opacity) } ?? content.alpha
        #endif
        guard alpha >= 0.99 else { return nil }
        let frame = content.convert(content.bounds, to: container)
        guard container.bounds.intersects(frame) else { return nil }
        let surface = container.mountedNoticeBacking ?? content
        #if os(macOS)
        let rect = surface.convert(surface.bounds, to: nil)
        let inWindow = CGRect(x: rect.minX, y: window.frame.height - rect.maxY, width: rect.width, height: rect.height)
        #else
        let inWindow = surface.convert(surface.bounds, to: window)
        #endif
        return VisiblePaneNotice(title: notice.title, detail: notice.detail, action: notice.action,
                                 actionLabel: notice.actionLabel, frame: frame, frameInWindow: inWindow)
    }
}
