import Foundation
import SwiftUI
import Thrush

// The host owns its session and terminal endpoint. The standalone demo peer listens here.
struct ServerAPI: Sendable {
    let session: URLSession

    func terminalSocket(clientID: String, size: Terminal.Size) -> URLSessionWebSocketTask {
        var endpoint = URLComponents(string: "ws://127.0.0.1:9138/socket")!
        endpoint.queryItems = [
            .init(name: "service", value: "terminal"),
            .init(name: "clientId", value: clientID),
            .init(name: "cols", value: String(size.columns)),
            .init(name: "rows", value: String(size.rows)),
        ]
        // The server reads a literal plus as a space in a query unless it is escaped.
        endpoint.percentEncodedQuery = endpoint.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return session.webSocketTask(with: endpoint.url!)
    }
}

@main
struct AppConsumer: App {
    var body: some Scene {
        WindowGroup { ShellWindow() }
    }
}

@MainActor private final class WindowModel: ObservableObject {
    @Published private(set) var tab = makeTab()

    func newShell() {
        guard tab.session.hasEnded else { return }
        tab = Self.makeTab()
    }

    private static func makeTab() -> ShellTab {
        ShellTab(tabID: UUID().uuidString, api: ServerAPI(session: .shared))
    }
}

private struct ShellWindow: View {
    @StateObject private var model = WindowModel()

    var body: some View {
        NavigationStack {
            TerminalPane(model.tab.session)
                .navigationTitle(title)
                .toolbar {
                    if model.tab.session.hasEnded {
                        Button("New Shell", action: model.newShell)
                    }
                }
        }
    }

    private var title: String {
        let session = model.tab.session
        return session.title.isEmpty ? "Terminal" : session.title
    }
}
