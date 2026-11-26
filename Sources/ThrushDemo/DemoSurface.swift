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
                        // The integration check mounts the public view exactly as an app would.
                        proofView(terminalSession)
                    } else {
                        session.terminalView(terminalSession)
                    }
                }
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
                MacToolbarProof(session: terminalSession, ignoresSafeArea: session.options.hostIgnoresSafeArea,
                                split: session.options.splitsToolbar)
            } else {
                session.terminalView(terminalSession)
            }
            #endif
        } else if session.options.benchmarkURL != nil {
            RendererSurface(view: session.view)
        } else {
            ContentUnavailableView("Couldn’t connect to the terminal", systemImage: "terminal",
                                   description: Text(session.endpointError ?? session.options.endpoint.absoluteString))
        }
    }

    #if os(iOS)
    /// An app's own `.ignoresSafeArea()`, written before the view extended under bars itself, must change nothing.
    @ViewBuilder private func proofView(_ terminalSession: TerminalSession) -> some View {
        if session.options.hostIgnoresSafeArea {
            TerminalView(terminalSession).ignoresSafeArea()
        } else {
            TerminalView(terminalSession)
        }
    }
    #endif
}

#if os(macOS)
private struct RendererSurface: NSViewRepresentable {
    let view: TerminalMetalView
    func makeNSView(context: Context) -> TerminalMetalView { view }
    func updateNSView(_ view: TerminalMetalView, context: Context) {}
}
#else
private struct RendererSurface: UIViewRepresentable {
    let view: TerminalMetalView
    func makeUIView(context: Context) -> TerminalMetalView { view }
    func updateUIView(_ view: TerminalMetalView, context: Context) {}
}
#endif
