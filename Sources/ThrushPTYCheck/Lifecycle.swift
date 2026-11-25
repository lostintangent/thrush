import Darwin
import Foundation
import Thrush

/// Run against the same disposable server as the numbered log, without observing binary frames.
struct PTYLifecycle {
    let endpoint: URL
    let token: String
    private let clientID = UUID().uuidString
    private let initialSize = Terminal.Size(columns: 80, rows: 24)

    func run() async throws {
        let first = try connect()
        let oldPID = try await freshShell(first)
        try await first.sendResize(to: .init(columns: 61, rows: 25))
        try await first.send(.text("KEEP=acorn; printf '\\r\\nSIZE-'; stty size\r"))
        try await row("SIZE-25 61", in: first)

        await first.hide()
        guard await first.show(), try await first.nextEvent() == .ready(resumed: true),
              try await first.nextEvent() == .replay else { throw PTYCheckFailure("Missing foreground replay") }
        // Read the replay itself before issuing a command so the live shell cannot mask a lost screen.
        let replay = await first.snapshot()
        guard replay.rows.contains(where: { $0.text == "SIZE-25 61" }),
              replay.size == Terminal.Size(columns: 61, rows: 25) else {
            throw PTYCheckFailure("Foreground replay lost the resized screen")
        }
        try await first.send(.text("printf '\\r\\nLIVE-%s-%d\\n' \"$KEEP\" $$\r"))
        try await row("LIVE-acorn-\(oldPID)", in: first)

        let owner = try connect()
        guard try await owner.nextEvent() == .ready(resumed: true),
              try await owner.nextEvent() == .replay else { throw PTYCheckFailure("Missing takeover replay") }
        var event = try await first.nextEvent()
        while event == .output { event = try await first.nextEvent() }
        guard event == .displaced else { throw PTYCheckFailure("Missing takeover event on the first socket") }
        guard await first.state == .displaced, await !first.show() else {
            throw PTYCheckFailure("Displaced client attempted an automatic reconnect")
        }
        try await owner.send(.text("printf '\\r\\nOWNER-%s-%d\\n' \"$KEEP\" $$\r"))
        try await row("OWNER-acorn-\(oldPID)", in: owner)
        try await owner.closeShell()
        try await waitForProcessExit(oldPID, within: .seconds(5))

        let orphan = try connect()
        let orphanPID = try await freshShell(orphan)
        await orphan.hide()
        let detached = ContinuousClock.now
        try await waitForProcessExit(orphanPID, within: .seconds(40))
        let orphanAge = detached.duration(to: .now)
        guard orphanAge >= .seconds(29), await orphan.show() else {
            throw PTYCheckFailure("Orphan expired early or could not reattach")
        }
        guard try await orphan.nextEvent() == .replaced, await orphan.state == .active else {
            throw PTYCheckFailure("The session did not adopt its replacement PTY")
        }
        let replacement = await orphan.snapshot()
        guard replacement.rows.allSatisfy({ $0.text.isEmpty }), replacement.cursorRow == 0, replacement.cursorColumn == 0,
              replacement.history.contains(where: { $0.text == "PID-\(orphanPID)" }) else {
            throw PTYCheckFailure("The replacement needs a blank home and the old shell in scrollback")
        }
        try await PTYCheck.enterFixture(orphan)
        try await row("THRUSH-\(token)", in: orphan)
        try await orphan.send(.text("printf '\\r\\nEXIT-%s\\n' final; exit\r"))
        while try await orphan.nextEvent() == .output {}
        guard await orphan.state == .ended, await !orphan.show(userInitiated: true),
              await orphan.snapshot().rows.contains(where: { $0.text == "EXIT-final" }) else {
            throw PTYCheckFailure("Real exit lost its final bytes or reopened the ended session")
        }
        let successor = try connect()
        let successorPID = try await freshShell(successor)
        guard successorPID != orphanPID, await successor.snapshot().history.isEmpty else {
            throw PTYCheckFailure("The app-created session inherited earlier history")
        }
        try await successor.closeShell()
        try await waitForProcessExit(successorPID, within: .seconds(5))
        print("Real PTY lifecycle passed (fresh, resize, foreground replay, takeover, close, orphan expiry after \(orphanAge), final output at exit)")
    }

    private func connect() throws -> SessionActor {
        try SessionActor(baseURL: endpoint, clientID: clientID, size: initialSize)
    }

    private func freshShell(_ session: SessionActor) async throws -> Int32 {
        guard try await session.nextEvent() == .ready(resumed: false),
              await session.snapshot().rows.allSatisfy({ $0.text.isEmpty }) else {
            throw PTYCheckFailure("Expected a fresh clean grid")
        }
        try await PTYCheck.enterFixture(session)
        try await row("THRUSH-\(token)", in: session)
        try await session.send(.text("stty -echo; printf '\\r\\nPID-%d\\n' $$\r"))
        while true {
            for row in await session.snapshot().rows where row.text.hasPrefix("PID-") {
                if let pid = Int32(row.text.dropFirst(4)), pid > 1 { return pid }
            }
            guard try await session.nextEvent() == .output else { throw PTYCheckFailure("Missing shell PID") }
        }
    }

    private func row(_ text: String, in session: SessionActor) async throws {
        while !(await session.snapshot().rows.contains { $0.text == text }) {
            guard try await session.nextEvent() == .output else { throw PTYCheckFailure("Missing row \(text)") }
        }
    }

    private func waitForProcessExit(_ pid: Int32, within timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while kill(pid, 0) == 0 || errno != ESRCH {
            guard ContinuousClock.now < deadline else { throw PTYCheckFailure("Disposable PTY \(pid) still exists") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
