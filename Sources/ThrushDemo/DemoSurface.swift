import SwiftUI
import ThrushUI

@MainActor
struct DemoSurface: View {
    @ObservedObject var session: DemoSession

    @ViewBuilder var body: some View {
        if let connection = session.connection {
            #if os(iOS)
            if session.options.checksToolbar {
                PhoneToolbarProof(connection: connection)
            } else {
                session.pane(connection)
            }
            #else
            session.pane(connection)
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
