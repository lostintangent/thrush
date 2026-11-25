#if os(macOS)
import SwiftUI
import Thrush

/// The integration host uses only the public pane, under a full-size window toolbar with a title and Close button.
struct MacToolbarProof: View {
    let session: TerminalSession
    var body: some View {
        TerminalPane(session)
            .navigationTitle("Terminal")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Close") { NSApp.terminate(nil) }
                }
            }
    }
}
#endif
