import SwiftUI
import Thrush

@MainActor
struct DemoSurface: View {
    @ObservedObject var session: DemoSession
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    @ViewBuilder var body: some View {
        if let terminalSession = session.terminalSession {
            #if os(iOS)
            NavigationStack {
                Group {
                    if session.options.checksToolbar {
                        // The integration check mounts the public pane exactly as an app would.
                        TerminalPane(terminalSession)
                    } else {
                        session.pane(terminalSession)
                    }
                }
                .ignoresSafeArea()
                .navigationTitle(terminalSession.title.isEmpty ? "Terminal" : terminalSession.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarVisibility(terminalSession.hasEnded || session.options.checksToolbar ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if terminalSession.hasEnded {
                            Button("New Shell", action: session.newShell)
                                .accessibilityIdentifier("demo.newShell")
                        }
                        if session.options.checksToolbar { Button("Close") { dismiss() } }
                    }
                }
            }
            #else
            if session.options.checksToolbar {
                MacToolbarProof(session: terminalSession)
            } else {
                session.pane(terminalSession)
            }
            #endif
        } else if session.options.benchmarkURL != nil {
            RendererSurface(view: session.view)
        } else {
            ContentUnavailableView("Couldn’t connect to the terminal", systemImage: "terminal",
                                   description: Text(session.endpointError ?? session.options.endpoint.absoluteString))
        }
    }
}

#if os(macOS)
private struct RendererSurface: NSViewRepresentable {
    let view: TerminalView
    func makeNSView(context: Context) -> TerminalView { view }
    func updateNSView(_ view: TerminalView, context: Context) {}
}
#else
private struct RendererSurface: UIViewRepresentable {
    let view: TerminalView
    func makeUIView(context: Context) -> TerminalView { view }
    func updateUIView(_ view: TerminalView, context: Context) {}
}
#endif
