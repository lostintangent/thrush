#if os(macOS)
import SwiftUI
import Thrush

/// The integration app uses only the public view, under a full-size window toolbar with a title and Close button,
/// alone or as a split view's detail.
struct MacToolbarProof: View {
    let session: TerminalSession
    /// Whether to add the modifier apps wrote before the view extended under bars itself, which must change nothing.
    let ignoresSafeArea: Bool
    /// Whether a sidebar with its own toolbar item floats over the view's leading edge.
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
        terminalView
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Close") { NSApp.terminate(nil) }
                }
            }
    }

    @ViewBuilder private var terminalView: some View {
        if ignoresSafeArea { TerminalView(session).ignoresSafeArea() } else { TerminalView(session) }
    }
}
#endif
