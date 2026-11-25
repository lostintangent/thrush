#if os(iOS)
import SwiftUI
import ThrushConnection
import ThrushUI
import UIKit

/// The integration host uses only the public pane. Its capture reads the mounted UIKit views.
struct PhoneToolbarProof: View {
    let connection: TerminalConnection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            TerminalPane(connection)
                .ignoresSafeArea()
                .navigationTitle("Terminal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                            .accessibilityIdentifier("toolbar.close")
                    }
                }
        }
    }

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
        let close = first(in: bar) { candidate in
            candidate.accessibilityIdentifier == "toolbar.close" || candidate.accessibilityLabel == "Close" ||
            (candidate as? UILabel)?.text == "Close" || (candidate as? UIButton)?.currentTitle == "Close"
        }
        return PhoneCapture.Toolbar(paneFrame: geometry.frame, safeAreaFrame: geometry.safeArea,
                                    navigationBarFrame: bar.convert(bar.bounds, to: window), firstCellFrame: geometry.firstCell,
                                    closeFrame: close.map { $0.convert($0.bounds, to: window) })
    }
}
#endif
