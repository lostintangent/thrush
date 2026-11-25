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
}

extension TerminalView {
    /// Used by the packaged capture and real-PTY probes after the native notice has appeared.
    package var visiblePaneNotice: VisiblePaneNotice? {
        var ancestor = superview
        while let item = ancestor {
            defer { ancestor = item.superview }
            guard let container = item as? TerminalPaneContainer else { continue }
            guard let notice = container.current, let content = container.mountedNoticeView,
                  content.window != nil, !content.isHidden, content.bounds.width > 0,
                  content.bounds.height > 0 else { return nil }
            #if os(macOS)
            let alpha = content.layer?.presentation().map { CGFloat($0.opacity) } ?? content.alphaValue
            #else
            let alpha = content.layer.presentation().map { CGFloat($0.opacity) } ?? content.alpha
            #endif
            guard alpha >= 0.99 else { return nil }
            let frame = content.convert(content.bounds, to: container)
            guard container.bounds.intersects(frame) else { return nil }
            return VisiblePaneNotice(title: notice.title, detail: notice.detail, action: notice.action,
                                     actionLabel: notice.actionLabel, frame: frame)
        }
        return nil
    }
}
