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
        guard UUID(uuidString: token) != nil, ["paced", "live", "suspended", "resize"].contains(scenario) else {
            throw CheckFailure("Run scripts/check-pty.sh")
        }
        if scenario == "resize" {
            try await checkUnmarkedResize(at: endpoint)
            return try await checkResize(at: endpoint, token: token, directory: directory)
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

    /// Rotates a program that paints only when asked, leaving its latest frame unread at each resize.
    /// The live screen takes each grid where the server answers, so it always equals a fresh replay.
    private static func checkResize(at endpoint: URL, token: String, directory: URL) async throws {
        let socket = terminalSocket(at: endpoint, clientID: UUID().uuidString)
        var live = SessionActor(size: .init(columns: 80, rows: 24), makeSocket: socket)
        func pump(until done: () async -> Bool) async throws {
            while !(await done()) {
                guard try await live.nextEvent() == .output else { throw CheckFailure("Missing PTY output") }
            }
        }
        func shows(_ text: String, at grid: Terminal.Size? = nil) async -> Bool {
            let snapshot = await live.snapshot()
            return (grid == nil || snapshot.size == grid) && snapshot.rows.contains { $0.text.hasSuffix(text) }
        }
        guard try await live.nextEvent() == .ready(resumed: false) else { throw CheckFailure("Expected a fresh PTY") }
        try await pump { await shows("THRUSH-\(token)") }
        try await live.send(.text("stty -echo && exec /usr/bin/python3 producer.py paint\r"))
        try await pump { await shows(", frame 0") }

        // The second step resizes twice before the first answer.
        let steps: [[Terminal.Size]] = [[.init(columns: 40, rows: 12)],
                                        [.init(columns: 60, rows: 30), .init(columns: 100, rows: 20)],
                                        [.init(columns: 80, rows: 10)]]
        var rows: [String] = []
        for (index, grids) in steps.enumerated() {
            try await live.send(.text("paint\r"))
            // Let the server parse the frame at the old grid while this client leaves it unread.
            try await Task.sleep(for: .milliseconds(300))
            let painted = await live.terminal.size
            for grid in grids { try await live.sendResize(to: grid) }
            guard await live.terminal.size == painted else { throw CheckFailure("Resized before the server answered") }
            try await pump { await shows(", frame \(index + 1)", at: grids.last!) }
            rows = await live.snapshot().rows.map(\.text)

            await live.hide()
            live = SessionActor(size: grids.last!, makeSocket: socket)
            guard try await live.nextEvent() == .ready(resumed: true), try await live.nextEvent() == .replay else {
                throw CheckFailure("Missing replay after a resize")
            }
            let replay = await live.snapshot().rows.map(\.text)
            guard replay == rows else { throw CheckFailure("The live screen disagrees with the replay:\n\(rows)\n\(replay)") }
        }
        try await live.send(.text("done\r"))
        while try await live.nextEvent() == .output {}
        guard await live.state == .ended else { throw CheckFailure("The painter did not exit") }
        let grids = [Terminal.Size(columns: 80, rows: 24)] + steps.joined()
        try JSONEncoder().encode(["grids": grids.map { "\($0.columns)x\($0.rows)" }, "rows": rows])
            .write(to: directory.appending(path: "client.json"))
    }

    /// A client from before resize answers marks none of its resizes, so the server sends it none.
    private static func checkUnmarkedResize(at endpoint: URL) async throws {
        let task = try terminalSocket(at: endpoint, clientID: UUID().uuidString)(.init(columns: 80, rows: 24))
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        guard case .string(let ready) = try await task.receive(),
              let control = try JSONSerialization.jsonObject(with: Data(ready.utf8)) as? [String: Any],
              control["type"] as? String == "ready", control["answersResize"] as? Bool == true else {
            throw CheckFailure("Expected a ready that promises resize answers")
        }
        try await task.send(.string(#"{"type":"resize","cols":40,"rows":12}"#))
        try await task.send(.data(Data(#"printf 'OLD-%s\n' "$(stty size)"\#r"#.utf8)))
        var output = Data()
        while output.range(of: Data("OLD-12 40".utf8)) == nil {
            switch try await task.receive() {
            case .data(let bytes): output.append(bytes)
            case .string(let text): throw CheckFailure("An unmarked resize got \(text)")
            @unknown default: throw CheckFailure("Unexpected message")
            }
        }
        try await task.send(.string(#"{"type":"close"}"#))
    }
}
