#if os(iOS)
import SwiftUI
import Thrush
import UIKit

/// The integration host uses only the public pane. Its capture reads the mounted UIKit views.
struct PhoneToolbarProof: View {
    let session: TerminalSession
    /// Whether to add the modifier hosts wrote before the pane extended under bars itself, which must change nothing.
    let ignoresSafeArea: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            pane
                .navigationTitle(session.title.isEmpty ? "Terminal" : session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var pane: some View {
        if ignoresSafeArea { TerminalPane(session).ignoresSafeArea() } else { TerminalPane(session) }
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
        return PhoneCapture.Toolbar(paneFrame: geometry.frame, safeAreaFrame: geometry.safeArea,
                                    navigationBarFrame: bar.convert(bar.bounds, to: window), firstCellFrame: geometry.firstCell)
    }
}
#endif
