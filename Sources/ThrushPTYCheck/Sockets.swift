import Foundation
import Thrush

private let checkSockets = URLSession(configuration: .ephemeral)

/// Builds each attachment's socket the way an app's factory does. Pass a separate URLSession
/// to act as a second app.
func terminalSocket(at endpoint: URL, clientID: String, in urlSession: URLSession = checkSockets)
    -> @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask {
    { size in
        guard var socket = URLComponents(url: endpoint.appending(path: "socket"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        socket.scheme = endpoint.scheme == "https" ? "wss" : "ws"
        socket.queryItems = [
            URLQueryItem(name: "service", value: "terminal"),
            URLQueryItem(name: "clientId", value: clientID),
            URLQueryItem(name: "cols", value: String(size.columns)),
            URLQueryItem(name: "rows", value: String(size.rows)),
        ]
        // The server's URLSearchParams reads an unescaped plus as a space.
        socket.percentEncodedQuery = socket.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = socket.url else { throw URLError(.badURL) }
        return urlSession.webSocketTask(with: url)
    }
}

/// Hears each binary frame once the session has applied it.
struct AppliedFrames: WebSocketFrameTrace {
    let body: @Sendable (Data) -> Void

    func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                 note: String?, stale: Bool?, closeCode: Int?, received: Int?, applied: Int?) {
        if event == "applied", case .data(let bytes) = message { body(bytes) }
    }
}
