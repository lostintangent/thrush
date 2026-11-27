#if os(iOS)
import SwiftUI
import Thrush
import UIKit

/// The integration app uses only the public view, under a visible navigation bar with an inline title and Close button.
struct PhoneToolbarProof: View {
    /// Whether to add the modifier apps wrote before the view extended under bars itself, which must change nothing.
    let ignoresSafeArea: Bool
    @StateObject private var model = WindowModel()

    var body: some View {
        NavigationStack {
            terminalView
                .navigationTitle(model.tab.session.title.isEmpty ? "Terminal" : model.tab.session.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if model.tab.session.hasEnded { Button("New Shell", action: model.newShell) }
                        Button("Close") {}
                    }
                }
        }
    }

    @ViewBuilder private var terminalView: some View {
        if ignoresSafeArea { TerminalView(model.tab.session).ignoresSafeArea() } else { TerminalView(model.tab.session) }
    }

    /// The capture reads the mounted UIKit views.
    static func measure(_ view: TerminalMetalView) -> PhoneCapture.Toolbar? {
        func first(in root: UIView, matching test: (UIView) -> Bool) -> UIView? {
            if test(root) { return root }
            for child in root.subviews {
                if let match = first(in: child, matching: test) { return match }
            }
            return nil
        }
        guard let geometry = view.canvasGeometryInWindow, let window = view.window,
              let bar = first(in: window, matching: { $0 is UINavigationBar && !$0.isHidden }),
              bar.bounds.height > 0 else { return nil }
        return PhoneCapture.Toolbar(canvasFrame: geometry.frame, safeAreaFrame: geometry.safeArea,
                                    navigationBarFrame: bar.convert(bar.bounds, to: window), firstCellFrame: geometry.firstCell)
    }
}
#endif
