#if os(iOS)
import Thrush
import UIKit

/// The integration host uses only the public pane. Its capture reads the mounted UIKit views.
@MainActor enum PhoneToolbarProof {
    private static func first(in root: UIView, matching test: (UIView) -> Bool) -> UIView? {
        if test(root) { return root }
        for child in root.subviews {
            if let match = first(in: child, matching: test) { return match }
        }
        return nil
    }

    static func terminal(in root: UIView) -> TerminalView? {
        first(in: root) { $0 is TerminalView } as? TerminalView
    }

    static func measure(_ view: TerminalView) -> PhoneCapture.Toolbar? {
        guard let geometry = view.paneGeometryInWindow, let window = view.window,
              let bar = first(in: window, matching: { $0 is UINavigationBar && !$0.isHidden }),
              bar.bounds.height > 0 else { return nil }
        return PhoneCapture.Toolbar(paneFrame: geometry.frame, safeAreaFrame: geometry.safeArea,
                                    navigationBarFrame: bar.convert(bar.bounds, to: window), firstCellFrame: geometry.firstCell)
    }
}
#endif
