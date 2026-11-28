import Foundation
import Thrush

// The app owns its URLSession and terminal endpoint. ThrushServer listens on ws://127.0.0.1:9138,
// and launching with `-endpoint ws://host:port` points the app elsewhere.
struct ServerAPI: Sendable {
    let session: URLSession
    let endpoint = UserDefaults.standard.string(forKey: "endpoint").flatMap(URL.init(string:))
        ?? URL(string: "ws://127.0.0.1:9138")!

    func terminalSocket(clientID: String, size: Terminal.Size) -> URLSessionWebSocketTask {
        var socket = URLComponents(url: endpoint.appending(path: "socket"), resolvingAgainstBaseURL: false)!
        socket.queryItems = [
            .init(name: "service", value: "terminal"),
            .init(name: "clientId", value: clientID),
            .init(name: "cols", value: String(size.columns)),
            .init(name: "rows", value: String(size.rows)),
        ]
        // The server reads a literal plus as a space in a query unless it is escaped.
        socket.percentEncodedQuery = socket.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return session.webSocketTask(with: socket.url!)
    }
}

@MainActor
struct ShellTab {
    let session: TerminalSession

    init(tabID: String, api: ServerAPI) {
        session = TerminalSession { size in
            api.terminalSocket(clientID: tabID, size: size)
        }
    }

    init(openTransport: @escaping @Sendable (Terminal.Size) async throws -> any TerminalTransport) {
        session = TerminalSession(openTransport: openTransport)
    }
}
