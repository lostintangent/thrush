import Foundation
import Synchronization
import Thrush

/// Sample immediately after each frame's bytes have been applied to Terminal.
private final class WireCapture: Sendable {
    struct Sample: Encodable {
        let uptimeNanoseconds: UInt64
        let cumulativeBytes: Int
    }

    struct State {
        var bytes = Data()
        var samples: [Sample] = []
        var finished = false
        var replayBytes = 0
        var replayFrames = 0
        var pending: Data?
        var receiptTime: UInt64 = 0
    }

    private let end = Data("\u{1B}[1;1HTHRUSH-END\u{1B}[K".utf8)
    private let state = Mutex(State())

    func receive(_ chunk: Data) {
        let receiptTime = DispatchTime.now().uptimeNanoseconds
        state.withLock { state in
            state.pending = chunk
            state.receiptTime = receiptTime
        }
    }

    /// The session reports whether this frame replaced the screen or added live output.
    func next(_ session: SessionActor) async throws -> SessionActor.Event {
        let event = try await session.nextEvent()
        state.withLock { state in
            guard let chunk = state.pending else { return }
            state.pending = nil
            if event == .replay {
                state.replayBytes += chunk.count
                state.replayFrames += 1
                return
            }
            let time = state.receiptTime
            state.bytes.append(chunk)
            state.samples.append(Sample(uptimeNanoseconds: time, cumulativeBytes: state.bytes.count))
            if state.bytes.suffix(128).range(of: end) != nil { state.finished = true }
        }
        return event
    }

    var finished: Bool { state.withLock { $0.finished } }
    var result: State { state.withLock { $0 } }
}

private struct PTYResult: Encodable {
    var receivedBytes: Int
    var replayBytes: Int
    var replayFrames: Int
    var commandToLiveEndMs: Double
    var commandToExitMs: Double
    var liveRows: [String]
    var replayRows: [String]
}

extension WebSocketCheck {
    /// Runs one numbered log through a real shell and writes the wire capture beside the producer's report.
    static func checkPTY(at endpoint: URL, token: String, scenario: String, directory: URL) async throws {
        guard UUID(uuidString: token) != nil, ["paced", "live", "suspended"].contains(scenario) else {
            throw CheckFailure("Run scripts/check-pty.sh")
        }
        let capture = WireCapture(), clientID = UUID().uuidString
        let size = Terminal.Size(columns: 80, rows: 24)
        let socket = terminalSocket(at: endpoint, clientID: clientID)
        let live = SessionActor(size: size, makeSocket: socket)
        await live.trace(with: AppliedFrames(body: capture.receive))
        guard try await capture.next(live) == .ready(resumed: false) else {
            throw CheckFailure("Expected a fresh PTY")
        }
        while !(await live.snapshot().rows.contains { $0.text == "THRUSH-\(token)" }) {
            guard try await capture.next(live) == .output else { throw CheckFailure("Missing disposable shell identity") }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        try await live.send(.text("stty -echo -onlcr && exec /usr/bin/python3 producer.py \(scenario)\r"))
        // The suspended shell exits while this process is stopped. The others repeat an end fence until acknowledged.
        var previous: SessionActor.Event?
        while true {
            let event = try await capture.next(live)
            if scenario == "suspended" ? event == .ended : capture.finished { break }
            guard event == .output || event == .replay else { throw CheckFailure("Missing the end of the log") }
            previous = event
        }
        let liveEnd = DispatchTime.now().uptimeNanoseconds
        let liveRows = await live.snapshot().rows.map(\.text)
        let replayRows: [String], exited: UInt64

        if scenario == "suspended" {
            // A reader that fell behind gets the final screen as a replay right before exit.
            guard previous == .replay else { throw CheckFailure("Missing the final replay before exit") }
            replayRows = liveRows
            exited = liveEnd
            let fresh = SessionActor(size: size, makeSocket: socket)
            guard try await fresh.nextEvent() == .ready(resumed: false) else {
                throw CheckFailure("Expected a fresh shell for the ended shell's ID")
            }
            try await fresh.closeShell()
        } else {
            await live.hide()
            // A fresh observer of the same shell restores the server's serialized grid. Its replay
            // and subsequent frames belong to a separate attachment and never enter the live totals.
            let restored = SessionActor(size: size, makeSocket: socket)
            guard try await restored.nextEvent() == .ready(resumed: true), try await restored.nextEvent() == .replay else {
                throw CheckFailure("Missing replay after the numbered log")
            }
            replayRows = await restored.snapshot().rows.map(\.text)
            try await restored.send(.text("ack\r"))
            while try await restored.nextEvent() == .output {}
            exited = DispatchTime.now().uptimeNanoseconds
            guard await restored.state == .ended,
                  await restored.snapshot().rows.contains(where: { $0.text == "THRUSH-FINAL" }) else {
                throw CheckFailure("Missing final screen row at exit")
            }
        }
        let captureResult = capture.result
        let result = PTYResult(receivedBytes: await live.receivedBytes,
                               replayBytes: captureResult.replayBytes, replayFrames: captureResult.replayFrames,
                               commandToLiveEndMs: Double(liveEnd - start) / 1e6,
                               commandToExitMs: Double(exited - start) / 1e6, liveRows: liveRows, replayRows: replayRows)
        try captureResult.bytes.write(to: directory.appending(path: "wire.bin"))
        try JSONEncoder().encode(captureResult.samples).write(to: directory.appending(path: "frames.json"))
        try JSONEncoder().encode(result).write(to: directory.appending(path: "client.json"))
    }
}
