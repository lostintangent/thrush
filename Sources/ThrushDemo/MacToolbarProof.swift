#if os(macOS)
import SwiftUI
import Thrush

/// The integration app uses only the public pane, under a full-size window toolbar with a title and Close button,
/// alone or as a split view's detail.
struct MacToolbarProof: View {
    let session: TerminalSession
    /// Whether to add the modifier hosts wrote before the pane extended under bars itself, which must change nothing.
    let ignoresSafeArea: Bool
    /// Whether a sidebar with its own toolbar item floats over the pane's leading edge.
    let split: Bool

    var body: some View {
        if split {
            NavigationSplitView {
                List(["Thrush"], id: \.self) { Label($0, systemImage: "terminal") }
                    .navigationSplitViewColumnWidth(200)
                    .toolbar {
                        ToolbarItem { Button("New", systemImage: "plus") {} }
                    }
            } detail: {
                detail
            }
        } else {
            detail
        }
    }

    private var detail: some View {
        pane
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Close") { NSApp.terminate(nil) }
                }
            }
    }

    @ViewBuilder private var pane: some View {
        if ignoresSafeArea { TerminalPane(session).ignoresSafeArea() } else { TerminalPane(session) }
    }
}
#endif
