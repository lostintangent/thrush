import Foundation
import Synchronization
import Thrush

struct PTYCheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Sample immediately after each frame's bytes have been applied to Terminal.
private final class WireCapture: Sendable {
    struct Sample: Encodable {
        let uptimeNanoseconds: UInt64
        let cumulativeBytes: Int
    }

    struct State {
        var bytes = Data()
        var samples: [Sample] = []
        var payloadStart: Int?
        var payloadStartTime: UInt64?
        var finished = false
        var replayBytes = 0
        var replayFrames = 0
        var pending: Data?
        var receiptTime: UInt64 = 0
    }

    private let begin = Data("THRUSH-BEGIN\r\n".utf8)
    private let end = Data("\u{1B}[1;1HTHRUSH-END\u{1B}[K".utf8)
    private let state = Mutex(State())

    func receive(_ chunk: Data) {
        let receiptTime = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            state.pending = chunk
            state.receiptTime = receiptTime
        }
    }

    /// The adapter reports whether this exact binary frame was a serialization or live output.
    func next(_ connection: TerminalWorker) async throws -> TerminalWorker.Event {
        let event = try await connection.nextEvent()
        state.withLock { state in
            guard let chunk = state.pending else { return }
            state.pending = nil
            if event == .resynchronized {
                state.replayBytes += chunk.count
                state.replayFrames += 1
                return
            }
            let time = state.receiptTime
            let previous = state.bytes.count
            state.bytes.append(chunk)
            state.samples.append(Sample(uptimeNanoseconds: time, cumulativeBytes: state.bytes.count))
            if state.payloadStart == nil {
                let range = max(0, previous - begin.count)..<state.bytes.count
                if let marker = state.bytes.range(of: begin, in: range) {
                    state.payloadStart = marker.upperBound
                    state.payloadStartTime = time
                }
            }
            if state.bytes.suffix(128).range(of: end) != nil { state.finished = true }
        }
        return event
    }

    var finished: Bool { state.withLock { $0.finished } }
    var result: State { state.withLock { $0 } }

    /// Limit the pull rate from the first live payload frame, without including shell startup time.
    func delayNextRead(at bytesPerSecond: Double) async throws {
        let nanoseconds = state.withLock { state -> UInt64 in
            guard let offset = state.payloadStart, let start = state.payloadStartTime else { return 0 }
            let due = start + UInt64(Double(state.bytes.count - offset) / bytesPerSecond * 1e9)
            let now = DispatchTime.now().uptimeNanoseconds
            return due > now ? due - now : 0
        }
        if nanoseconds > 0 { try await Task.sleep(nanoseconds: nanoseconds) }
    }
}

@main
struct PTYCheck {
    private struct Result: Encodable {
        var receivedBytes: Int
        var appliedBytes: Int
        var replayBytes: Int
        var replayFrames: Int
        var commandToLiveEndMs: Double
        var commandToExitMs: Double
        var liveRows: [String]
        var replayRows: [String]
    }

    static var fixtureCommand: String? {
        guard let command = ProcessInfo.processInfo.environment["THRUSH_PTY_CHECK_BOOTSTRAP"], !command.isEmpty else { return nil }
        return command
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme ?? "") && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? "")
    }

    static func enterFixture(_ connection: TerminalWorker) async throws {
        if let command = fixtureCommand { try await connection.send(.text(command)) }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "check-exit-screen" {
            try ReaderComparison.checkExitScreen(URL(fileURLWithPath: args[2]))
            return
        }
        if args.dropFirst().first == "reader" {
            try await ReaderComparison.run(args)
            return
        }
        guard args.count == 5 || args.count == 6, let endpoint = URL(string: args[1]),
              isLoopback(endpoint), UUID(uuidString: args[2]) != nil,
              ["paced", "live", "limited", "suspended", "lifecycle"].contains(args[3]) else {
            throw PTYCheckFailure("Run scripts/check-pty.sh to create a disposable server")
        }
        let token = args[2], scenario = args[3]
        if scenario == "lifecycle" {
            try await PTYLifecycle(endpoint: endpoint, token: token).run()
            return
        }
        let bytesPerSecond = args.count == 6 ? Double(args[5]) : nil
        if scenario == "limited", !(bytesPerSecond.map { $0.isFinite && $0 > 0 } ?? false) {
            throw PTYCheckFailure("Expected the calibrated live-reader rate limit")
        }

        let directory = URL(filePath: args[4], directoryHint: .isDirectory)
        let capture = WireCapture(), clientID = UUID().uuidString
        let size = Terminal.Size(columns: 80, rows: 24)
        let live = try TerminalWorker(baseURL: endpoint, clientID: clientID, size: size, onOutput: capture.receive)
        guard try await capture.next(live) == .ready(resumed: false) else {
            throw PTYCheckFailure("Expected a fresh PTY")
        }
        try await enterFixture(live)
        while !(await live.snapshot().rows.contains { $0.text == "THRUSH-\(token)" }) {
            guard try await capture.next(live) == .output else { throw PTYCheckFailure("Missing disposable shell identity") }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        try await live.send(.text("stty -echo -onlcr && exec /usr/bin/python3 producer.py \(scenario)\r"))
        while !capture.finished {
            let event = try await capture.next(live)
            guard event == .output || event == .resynchronized else { throw PTYCheckFailure("Missing live end fence") }
            if let bytesPerSecond, !capture.finished { try await capture.delayNextRead(at: bytesPerSecond) }
        }
        let liveEnd = DispatchTime.now().uptimeNanoseconds
        let liveRows = await live.snapshot().rows.map(\.text)
        await live.detach()

        // A fresh observer of the same shell restores the server's serialized grid. Its replay
        // and subsequent frames belong to a separate attachment and never enter the live totals.
        let restored = try TerminalWorker(baseURL: endpoint, clientID: clientID, size: size)
        guard try await restored.nextEvent() == .ready(resumed: true), try await restored.nextEvent() == .output else {
            throw PTYCheckFailure("Missing replay after the numbered log")
        }
        let replayRows = await restored.snapshot().rows.map(\.text)
        try await restored.send(.text("ack\r"))
        while try await restored.nextEvent() == .output {}
        let exited = DispatchTime.now().uptimeNanoseconds
        guard await restored.state == .ended,
              await restored.snapshot().rows.contains(where: { $0.text == "THRUSH-FINAL" }) else {
            throw PTYCheckFailure("Missing final screen row at exit")
        }
        let captureResult = capture.result
        let result = Result(receivedBytes: await live.receivedBytes, appliedBytes: await live.appliedBytes,
                            replayBytes: captureResult.replayBytes, replayFrames: captureResult.replayFrames,
                            commandToLiveEndMs: Double(liveEnd - start) / 1e6,
                            commandToExitMs: Double(exited - start) / 1e6, liveRows: liveRows, replayRows: replayRows)
        try captureResult.bytes.write(to: directory.appending(path: "wire.bin"))
        try JSONEncoder().encode(captureResult.samples).write(to: directory.appending(path: "frames.json"))
        try JSONEncoder().encode(result).write(to: directory.appending(path: "client.json"))
    }
}
