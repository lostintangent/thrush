import Foundation
import Thrush
import ThrushConnection

/// The same native socket with and without Thrush's parser, measured over identical raw payloads.
enum ReaderComparison {
    struct Result: Encodable {
        var reader: String
        var receivedBytes = 0
        var appliedBytes: Int?
        var binaryFrames = 0
    }

    static func run(_ args: [String]) async throws {
        guard args.count == 6, ["thrush", "urlsession"].contains(args[2]), let url = URL(string: args[3]),
              url.host == "127.0.0.1", url.scheme == "http", UUID(uuidString: args[4]) != nil else {
            throw PTYCheckFailure("Run scripts/check-pty.sh --readers")
        }
        let reader = args[2], id = args[4], directory = URL(filePath: args[5], directoryHint: .isDirectory)
        let ready = directory.appending(path: "reader-ready")
        var result = Result(reader: reader)
        if reader == "thrush" {
            let connection = try TerminalConnection(baseURL: url, clientID: id, size: .init(columns: 80, rows: 24))
            guard try await connection.nextEvent() == .ready(resumed: false) else { throw PTYCheckFailure("Expected fresh PTY") }
            try Data().write(to: ready)
            while try await connection.nextEvent() == .output { result.binaryFrames += 1 }
            guard await connection.state == .ended else { throw PTYCheckFailure("Expected shell exit") }
            result.receivedBytes = await connection.receivedBytes
            result.appliedBytes = await connection.appliedBytes
        } else {
            // Match the adapter’s ephemeral URLSession and endpoint for a transport-only reader.
            var endpoint = URLComponents(url: url.appending(path: "socket"), resolvingAgainstBaseURL: false)!
            endpoint.scheme = "ws"
            endpoint.queryItems = [
                URLQueryItem(name: "service", value: "terminal"), URLQueryItem(name: "clientId", value: id),
                URLQueryItem(name: "cols", value: "80"), URLQueryItem(name: "rows", value: "24")
            ]
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let socket = session.webSocketTask(with: endpoint.url!)
            socket.resume()
            var attached = false
            read: while true {
                switch try await socket.receive() {
                case let .data(data):
                    guard attached else { throw PTYCheckFailure("Binary payload preceded ready") }
                    result.receivedBytes += data.count
                    result.binaryFrames += 1
                case let .string(text):
                    let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    if !attached, message?["type"] as? String == "ready", message?["resumed"] as? Bool == false {
                        attached = true
                        try Data().write(to: ready)
                    } else if attached, message?["type"] as? String == "exit" {
                        break read
                    } else {
                        throw PTYCheckFailure("Unexpected WebSocket control message")
                    }
                @unknown default: throw PTYCheckFailure("Unknown WebSocket message")
                }
            }
        }
        try JSONEncoder().encode(result).write(to: directory.appending(path: "client.json"))
    }
}
