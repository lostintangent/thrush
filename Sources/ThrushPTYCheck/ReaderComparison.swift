import Foundation
import Synchronization
import Thrush

/// The same native socket with and without Thrush's parser, measured over identical WebSocket payloads.
enum ReaderComparison {
    struct Result: Encodable {
        var reader: String
        var setupBytes = 0
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
        _ = terminal.write(Span(viewing: bytes.bytes))
        let expected = (131051...131072).map { "THRUSH \($0) " + String(repeating: ".", count: 48) }
                     + ["THRUSH-SHELL-EXIT", ""]
        guard (0..<24).map({ terminal.text(inRow: $0) }) == expected else {
            throw PTYCheckFailure("Final exit replay diverged from the expected numbered screen")
        }
    }

    /// A supplied server starts in its own shell. The producer cannot start until the full nonce line
    /// has reached this reader, so the measured stream starts on a message boundary after setup.
    private static func readSetup(id: String, next: () async throws -> Data) async throws -> Int {
        let marker = Data("\r\nTHRUSH-SETUP-\(id)\r\n".utf8)
        var tail = Data()
        var bytes = 0
        while tail != marker {
            let frame = try await next()
            bytes += frame.count
            tail.append(frame)
            tail = Data(tail.suffix(marker.count))
        }
        return bytes
    }

    static func run(_ args: [String]) async throws {
        guard args.count == 6, ["thrush", "urlsession", "silent"].contains(args[2]), let url = URL(string: args[3]),
              PTYCheck.isLoopback(url), UUID(uuidString: args[4]) != nil else {
            throw PTYCheckFailure("Run scripts/check-pty.sh --readers")
        }
        let reader = args[2], id = args[4], directory = URL(filePath: args[5], directoryHint: .isDirectory)
        let ready = directory.appending(path: "reader-ready")
        var result = Result(reader: reader)
        if reader == "thrush" || reader == "silent" {
            let lastFrame = Mutex(Data())
            let session = SessionActor(size: .init(columns: 80, rows: 24), makeSocket: terminalSocket(at: url, clientID: id))
            await session.trace(with: AppliedFrames { data in lastFrame.withLock { $0 = data } })
            guard try await session.nextEvent() == .ready(resumed: false) else { throw PTYCheckFailure("Expected fresh PTY") }
            if PTYCheck.fixtureCommand != nil {
                try await PTYCheck.enterFixture(session)
                result.setupBytes = try await readSetup(id: id) {
                    guard try await session.nextEvent() == .output else { throw PTYCheckFailure("Missing fixture setup fence") }
                    return lastFrame.withLock { $0 }
                }
            }
            try Data().write(to: ready)
            if reader == "silent" {
                try await SilentRecoveryCheck.run(session, id: id, directory: directory, setupBytes: result.setupBytes)
                return
            }
            drain: while true {
                switch try await session.nextEvent() {
                case .output: result.binaryFrames += 1
                case .replay:
                    result.replayFrames += 1
                    result.replayBytes += lastFrame.withLock { $0.count }
                case .exit: break drain
                default: throw PTYCheckFailure("Unexpected lifecycle transition during the burst")
                }
            }
            guard await session.state == .ended else { throw PTYCheckFailure("Expected shell exit") }
            result.receivedBytes = await session.receivedBytes - result.setupBytes
            result.appliedBytes = await session.appliedBytes - result.setupBytes
        } else {
            // A transport-only reader opens the same socket as the session's.
            let socket = try terminalSocket(at: url, clientID: id)(.init(columns: 80, rows: 24))
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
                        if let command = PTYCheck.fixtureCommand {
                            try await socket.send(.data(Data(command.utf8)))
                            result.setupBytes = try await readSetup(id: id) {
                                guard case let .data(bytes) = try await socket.receive() else { throw PTYCheckFailure("Missing fixture setup fence") }
                                return bytes
                            }
                        }
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
