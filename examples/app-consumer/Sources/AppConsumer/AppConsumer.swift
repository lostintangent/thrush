import Foundation
import SwiftUI
import Thrush

// The host owns its session and terminal endpoint. The standalone demo peer listens here.
struct ServerAPI: Sendable {
    let session: URLSession

    func terminalSocket(clientID: String, size: Terminal.Size) -> URLSessionWebSocketTask {
        let endpoint = URL(string: "ws://127.0.0.1:9138/socket")!
        return session.webSocketTask(with: endpoint.appending(queryItems: [
            .init(name: "service", value: "terminal"),
            .init(name: "clientId", value: clientID),
            .init(name: "cols", value: String(size.columns)),
            .init(name: "rows", value: String(size.rows)),
        ]))
    }
}

@main
struct AppConsumer: App {
    private let tab = ShellTab(clientID: UUID().uuidString, api: ServerAPI(session: .shared))

    var body: some Scene {
        WindowGroup { tab.pane }
    }
}
