import Darwin
import Foundation
import Thrush
import ThrushConnection

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

        await first.detach()
        guard await first.attach(), try await first.nextEvent() == .ready(resumed: true),
              try await first.nextEvent() == .output else { throw PTYCheckFailure("Missing foreground replay") }
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
              try await owner.nextEvent() == .output else { throw PTYCheckFailure("Missing takeover replay") }
        var event = try await first.nextEvent()
        while event == .output { event = try await first.nextEvent() }
        guard event == .displaced else { throw PTYCheckFailure("Missing takeover event on the first socket") }
        guard await first.state == .displaced, await !first.attach() else {
            throw PTYCheckFailure("Displaced client attempted an automatic reconnect")
        }
        try await owner.send(.text("printf '\\r\\nOWNER-%s-%d\\n' \"$KEEP\" $$\r"))
        try await row("OWNER-acorn-\(oldPID)", in: owner)
        try await owner.closeShell()
        try await waitForProcessExit(oldPID, within: .seconds(5))

        let orphan = try connect()
        let orphanPID = try await freshShell(orphan)
        await orphan.detach()
        let detached = ContinuousClock.now
        try await waitForProcessExit(orphanPID, within: .seconds(40))
        let orphanAge = detached.duration(to: .now)
        guard orphanAge >= .seconds(29), await orphan.attach() else {
            throw PTYCheckFailure("Orphan expired early or could not reattach")
        }
        _ = try await freshShell(orphan)
        try await orphan.send(.text("printf '\\r\\nEXIT-%s\\n' final; exit\r"))
        while try await orphan.nextEvent() == .output {}
        guard await orphan.state == .ended,
              await orphan.snapshot().rows.contains(where: { $0.text == "EXIT-final" }) else {
            throw PTYCheckFailure("Real shell exit preceded its last bytes")
        }
        print("Real PTY lifecycle passed (fresh, resize, foreground replay, takeover, close, orphan expiry after \(orphanAge), final output at exit)")
    }

    private func connect() throws -> TerminalConnection {
        try TerminalConnection(baseURL: endpoint, clientID: clientID, size: initialSize)
    }

    private func freshShell(_ connection: TerminalConnection) async throws -> Int32 {
        guard try await connection.nextEvent() == .ready(resumed: false),
              await connection.snapshot().rows.allSatisfy({ $0.text.isEmpty }) else {
            throw PTYCheckFailure("Expected a fresh clean grid")
        }
        try await row("THRUSH-\(token)", in: connection)
        try await connection.send(.text("stty -echo; printf '\\r\\nPID-%d\\n' $$\r"))
        while true {
            for row in await connection.snapshot().rows where row.text.hasPrefix("PID-") {
                if let pid = Int32(row.text.dropFirst(4)), pid > 1 { return pid }
            }
            guard try await connection.nextEvent() == .output else { throw PTYCheckFailure("Missing shell PID") }
        }
    }

    private func row(_ text: String, in connection: TerminalConnection) async throws {
        while !(await connection.snapshot().rows.contains { $0.text == text }) {
            guard try await connection.nextEvent() == .output else { throw PTYCheckFailure("Missing row \(text)") }
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
