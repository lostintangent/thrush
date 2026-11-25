import Foundation
import Synchronization
import Thrush

/// The same native socket with and without Thrush's parser, measured over identical raw payloads.
enum ReaderComparison {
    struct Result: Encodable {
        var reader: String
        var receivedBytes = 0
        var appliedBytes: Int?
        var binaryFrames = 0
        var replayBytes = 0
        var replayFrames = 0
    }

    /// Reconstruct the final replacement screen and subsequent live bytes observed before exit.
    /// Each of the last 22 numbered records, the shell's final marker and the blank cursor row must survive.
    static func checkExitScreen(_ capture: URL) throws {
        let bytes = try Data(contentsOf: capture)
        var terminal = Terminal(size: .init(columns: 80, rows: 24))
        _ = bytes.withUnsafeBytes { terminal.receive($0.bindMemory(to: UInt8.self)) }
        let expected = (131051...131072).map { "THRUSH \($0) " + String(repeating: ".", count: 48) }
                     + ["THRUSH-SHELL-EXIT", ""]
        guard (0..<24).map({ terminal.text(inRow: $0) }) == expected else {
            throw PTYCheckFailure("Final exit replay diverged from the expected numbered screen")
        }
    }

    static func run(_ args: [String]) async throws {
        guard args.count == 6, ["thrush", "urlsession", "silent"].contains(args[2]), let url = URL(string: args[3]),
              url.host == "127.0.0.1", url.scheme == "http", UUID(uuidString: args[4]) != nil else {
            throw PTYCheckFailure("Run scripts/check-pty.sh --readers")
        }
        let reader = args[2], id = args[4], directory = URL(filePath: args[5], directoryHint: .isDirectory)
        let ready = directory.appending(path: "reader-ready")
        var result = Result(reader: reader)
        if reader == "thrush" || reader == "silent" {
            let lastFrame = Mutex(0)
            let connection = try TerminalConnection(baseURL: url, clientID: id, size: .init(columns: 80, rows: 24),
                                                    onOutput: { data in lastFrame.withLock { $0 = data.count } })
            guard try await connection.nextEvent() == .ready(resumed: false) else { throw PTYCheckFailure("Expected fresh PTY") }
            try Data().write(to: ready)
            if reader == "silent" {
                try await SilentRecoveryCheck.run(connection, id: id, directory: directory)
                return
            }
            drain: while true {
                switch try await connection.nextEvent() {
                case .output: result.binaryFrames += 1
                case .resynchronized:
                    result.replayFrames += 1
                    result.replayBytes += lastFrame.withLock { $0 }
                case .exit: break drain
                default: throw PTYCheckFailure("Unexpected lifecycle transition during the burst")
                }
            }
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
            var awaitingReplay = false
            read: while true {
                switch try await socket.receive() {
                case let .data(data):
                    guard attached else { throw PTYCheckFailure("Binary payload preceded ready") }
                    result.receivedBytes += data.count
                    if awaitingReplay {
                        awaitingReplay = false
                        result.replayFrames += 1
                        result.replayBytes += data.count
                    } else {
                        result.binaryFrames += 1
                    }
                case let .string(text):
                    let message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
                    if !attached, message?["type"] as? String == "ready", message?["resumed"] as? Bool == false {
                        attached = true
                        try Data().write(to: ready)
                    } else if attached, !awaitingReplay, message?["type"] as? String == "ready", message?["resumed"] as? Bool == true {
                        awaitingReplay = true
                    } else if attached, !awaitingReplay, message?["type"] as? String == "exit" {
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
