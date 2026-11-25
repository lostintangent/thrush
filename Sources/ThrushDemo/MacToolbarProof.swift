#if os(macOS)
import SwiftUI
import Thrush

/// The integration host uses only the public pane, under a full-size window toolbar with a title and Close button.
struct MacToolbarProof: View {
    let session: TerminalSession
    /// Whether to add the modifier hosts wrote before the pane extended under bars itself, which must change nothing.
    let ignoresSafeArea: Bool
    var body: some View {
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
