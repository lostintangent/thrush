#if os(iOS)
import Thrush
import UIKit

/// The integration app uses only the public view. Its capture reads the mounted UIKit views.
@MainActor enum PhoneToolbarProof {
    private static func first(in root: UIView, matching test: (UIView) -> Bool) -> UIView? {
        if test(root) { return root }
        for child in root.subviews {
            if let match = first(in: child, matching: test) { return match }
        }
        return nil
    }

    static func terminal(in root: UIView) -> TerminalMetalView? {
        first(in: root) { $0 is TerminalMetalView } as? TerminalMetalView
    }

    static func measure(_ view: TerminalMetalView) -> PhoneCapture.Toolbar? {
        guard let geometry = view.canvasGeometryInWindow, let window = view.window,
              let bar = first(in: window, matching: { $0 is UINavigationBar && !$0.isHidden }),
              bar.bounds.height > 0 else { return nil }
        return PhoneCapture.Toolbar(canvasFrame: geometry.frame, safeAreaFrame: geometry.safeArea,
                                    navigationBarFrame: bar.convert(bar.bounds, to: window), firstCellFrame: geometry.firstCell)
    }
}
#endif
