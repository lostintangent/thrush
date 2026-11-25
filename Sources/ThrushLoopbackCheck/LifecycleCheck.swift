import Foundation
import Synchronization
import Thrush

/// Two host instances share a shell ID. The peer controls orphan time and acknowledges each
/// expected write on the socket that owns the shell.
struct LifecycleCheck {
    typealias Failure = LoopbackCheck.CheckFailure

    let endpoint: URL
    private let size = Terminal.Size(columns: 16, rows: 3)
    private let palette = Terminal.Palette(
        foreground: Terminal.Palette.default.background, background: Terminal.Palette.default.foreground,
        ansi: Terminal.Palette.default.ansi
    )

    func run() async throws {
        let first = try open()
        try await expectReady(first, resumed: false)
        try await expectOutput(first, rows: ["old-only", "old", ""])
        try await expectOutput(first, rows: ["old-only", "old", ""])
        let wide = Terminal.Size(columns: 18, rows: 3)
        try await first.sendResize(to: wide)
        try await first.sendResize(to: wide)
        try await expectOutput(first, rows: ["old-only", "old.", ""])
        guard await first.snapshot().size == wide else { throw Failure("Lost the active resize") }

        try await resumeWithPendingRead(first)
        try await expectReady(first, resumed: true)
        try await expectEditorReplay(first, row: "alt")
        try await expectOutput(first, rows: ["alt!", "", ""])
        try await first.send(.key(.up))
        try await expectOutput(first, rows: ["alt!A", "", ""])

        let hostSession = URLSession(configuration: .ephemeral)
        defer { hostSession.invalidateAndCancel() }
        let second = try open(in: hostSession)
        try await expectReady(second, resumed: true)
        try await expectEditorReplay(second, row: "alt!A")
        try await expectOutput(second, rows: ["alt!A!", "", ""])
        try await expectDisplacement(first)
        try await second.send(.key(.up))
        try await expectOutput(second, rows: ["alt!A!B", "", ""])
        try await checkpoint("owner-b")

        guard await first.attach(userInitiated: true) else { throw Failure("Could not reclaim the shell") }
        try await first.sendResize(to: .init(columns: 20, rows: 3))
        try await expectReady(first, resumed: true)
        let editorSize = Terminal.Size(columns: 17, rows: 3)
        try await first.sendResize(to: editorSize)
        guard await first.snapshot().size == size else { throw Failure("Resized before the peer's replay") }
        try await checkpoint("replay")
        try await expectEditorReplay(first, row: "alt!A!B")
        guard await first.snapshot().size == editorSize else { throw Failure("Lost the resize during replay") }
        try await expectDisplacement(second)
        try await first.send(.text("r"))
        try await expectOutput(first, rows: ["alt!A!BR", "", ""])
        try await expectOutput(first, rows: ["one", "two", "shell$"])
        let restored = await first.snapshot()
        guard !restored.isAlternate, restored.history.map(\.text) == ["history"],
              restored.cursorRow == 2, restored.cursorColumn == 6 else {
            throw Failure("Leaving the replayed editor lost or duplicated shell history or cursor position")
        }

        await first.detach()
        try await first.sendResize(to: size)
        try await checkpoint("expire")
        guard await first.attach() else { throw Failure("Could not attach after orphan expiry") }
        // The peer withholds ready until the rejected keystroke has had a chance to queue.
        try await rejectInput(first)
        try await checkpoint("ready")
        try await expectReady(first, resumed: false)
        try await expectOutput(first, rows: ["new$ ", "", ""])
        try await first.send(.key(.up))
        try await expectOutput(first, rows: ["new$ N", "", ""])
        try await closeWithPendingRead(first)
        try await checkpoint("closed")
        try await expectEnded(first, closed: true)

        // The previous socket's displacement must leave the host-owned session usable.
        let observed = Mutex(Data())
        let final = try open(in: hostSession) { bytes in observed.withLock { $0.append(bytes) } }
        try await expectReady(final, resumed: false)
        try await expectOutput(final, rows: ["last ", "", ""])
        try await expectOutput(final, rows: ["last bytes", "", ""])
        let expected = Data("last bytes".utf8)
        guard try await final.nextEvent() == .exit, await final.text(inRow: 0) == "last bytes",
              observed.withLock({ $0 }) == expected, await final.receivedBytes == expected.count,
              await final.appliedBytes == expected.count else {
            throw Failure("Exit must follow the final output and preserve it on screen")
        }
        try await expectEnded(final, closed: false)
    }

    private func open() throws -> TerminalWorker {
        try TerminalWorker(baseURL: endpoint, clientID: "thrush lifecycle", size: size, palette: palette)
    }

    private func open(in session: URLSession,
                      onOutput: (@Sendable (Data) -> Void)? = nil) throws -> TerminalWorker {
        TerminalWorker(size: size, palette: palette, onOutput: onOutput) { grid in
            let address = endpoint.appending(path: "socket").appending(queryItems: [
                URLQueryItem(name: "service", value: "terminal"),
                URLQueryItem(name: "clientId", value: "thrush lifecycle"),
                URLQueryItem(name: "cols", value: String(grid.columns)),
                URLQueryItem(name: "rows", value: String(grid.rows)),
            ])
            var location = URLComponents(url: address, resolvingAgainstBaseURL: false)
            location?.scheme = endpoint.scheme == "https" ? "wss" : "ws"
            guard let socketURL = location?.url else { throw Failure("Invalid test socket URL") }
            return session.webSocketTask(with: socketURL)
        }
    }

    private func expectReady(_ connection: TerminalWorker, resumed: Bool) async throws {
        guard try await connection.nextEvent() == .ready(resumed: resumed) else {
            throw Failure("Expected ready(resumed: \(resumed)) before any output")
        }
        let grid = await connection.snapshot()
        guard grid.size == size, grid.palette == palette, grid.rows.allSatisfy({ $0.text.isEmpty }),
              grid.history.isEmpty, grid.normalHistoryCount == 0, !grid.isAlternate,
              grid.cursorRow == 0, grid.cursorColumn == 0 else {
            throw Failure("Ready must start on a clean grid at the requested size and palette")
        }
        if resumed { try await rejectInput(connection) }
    }

    private func expectOutput(_ connection: TerminalWorker, rows: [String]) async throws {
        let event = try await connection.nextEvent()
        guard event == .output else { throw Failure("Expected output for \(rows), got \(event)") }
        let actual = await connection.snapshot().rows.map(\.text)
        guard actual == rows else { throw Failure("Expected \(rows), got \(actual)") }
    }

    private func expectEditorReplay(_ connection: TerminalWorker, row: String) async throws {
        try await expectOutput(connection, rows: [row, "", ""])
        let grid = await connection.snapshot()
        guard grid.isAlternate, grid.normalHistoryCount == 1, grid.cursorRow == 0,
              grid.cursorColumn == row.utf8.count else {
            throw Failure("Replayed alternate screen, saved shell history or cursor diverged")
        }
    }

    private func expectDisplacement(_ connection: TerminalWorker) async throws {
        guard try await connection.nextEvent() == .displaced else {
            throw Failure("Expected the peer to displace the old socket with close code 4000")
        }
        await connection.detach() // The user backgrounds and returns to the displaced window.
        guard await connection.state == .displaced, await !connection.attach() else {
            throw Failure("Foregrounding a displaced owner must wait for user input")
        }
        try await rejectInput(connection)
    }

    private func expectEnded(_ connection: TerminalWorker, closed: Bool) async throws {
        guard await connection.state == .ended, await !connection.attach() else {
            throw Failure("A closed or exited shell must stay ended")
        }
        if closed, await connection.attach(userInitiated: true) { throw Failure("Explicitly closed shell restarted") }
        try await rejectInput(connection)
    }

    private func rejectInput(_ connection: TerminalWorker) async throws {
        do { try await connection.send(.text("stale")) }
        catch { return }
        throw Failure("Accepted input outside the active attachment")
    }

    private func resumeWithPendingRead(_ connection: isolated TerminalWorker) async throws {
        // Each immediate task enters the actor and suspends at its first I/O wait. The input is
        // already queued for this socket when we detach, before its writer gets the actor again.
        let pendingRead = Task.immediate { try await connection.nextEvent() }
        let pendingInput = Task.immediate { try await connection.send(.text("stale")) }
        connection.detach()
        try await connection.sendResize(to: size)
        guard connection.attach() else { throw Failure("Could not resume on foreground return") }
        try await checkpoint("detached")
        guard case .failure = await pendingRead.result,
              case .failure(let error) = await pendingInput.result, error is CancellationError,
              connection.state == .connecting else {
            throw Failure("Stale I/O survived detachment or altered the new attachment")
        }
    }

    private func closeWithPendingRead(_ connection: isolated TerminalWorker) async throws {
        let pendingRead = Task.immediate { try await connection.nextEvent() }
        try await connection.closeShell()
        guard case .failure = await pendingRead.result else {
            throw Failure("A receive survived explicit close")
        }
    }

    private func checkpoint(_ name: String) async throws {
        let (_, response) = try await URLSession.shared.data(from: endpoint.appending(path: "check/\(name)"))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure("Peer rejected lifecycle checkpoint \(name)")
        }
    }
}
