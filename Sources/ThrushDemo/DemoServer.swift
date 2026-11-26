import Foundation
import Thrush

/// The demo reaches its terminal server the way an app does, with its own URLSession and a
/// socket factory for each session.
final class DemoServer: Sendable {
    private let socket: URLComponents
    private let urlSession = URLSession(configuration: .ephemeral)

    /// Accepts an http, https, ws or wss address without a query or fragment.
    init?(endpoint: URL) {
        guard var socket = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              socket.host != nil, socket.query == nil, socket.fragment == nil else { return nil }
        switch socket.scheme {
        case "http", "ws": socket.scheme = "ws"
        case "https", "wss": socket.scheme = "wss"
        default: return nil
        }
        socket.path = endpoint.appending(path: "socket").path
        self.socket = socket
    }

    deinit { urlSession.invalidateAndCancel() }

    func makeSocket(clientID: String) -> @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask {
        { [self] size in
            var location = socket
            location.queryItems = [
                URLQueryItem(name: "service", value: "terminal"),
                URLQueryItem(name: "clientId", value: clientID),
                URLQueryItem(name: "cols", value: String(size.columns)),
                URLQueryItem(name: "rows", value: String(size.rows)),
            ]
            // The server's URLSearchParams reads an unescaped plus as a space.
            location.percentEncodedQuery = location.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = location.url else { throw URLError(.badURL) }
            return urlSession.webSocketTask(with: url)
        }
    }
}
