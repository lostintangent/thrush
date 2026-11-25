import Foundation
import Synchronization
import Thrush

/// The clock records requested backoff without wall-clock delays. One sleep intentionally ignores
/// task cancellation until the driver releases it, like a timer callback already in flight.
private actor RetryClock {
    private(set) var delays: [Duration] = []
    private var hold = false
    private var sleeper: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func sleep(for delay: Duration) async {
        delays.append(delay)
        guard hold else { return }
        await withCheckedContinuation { continuation in
            sleeper = continuation
            observer?.resume()
            observer = nil
        }
    }

    func pauseNextSleep() { hold = true }
    func waitForSleeper() async {
        guard sleeper == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }
    func advance() {
        hold = false
        sleeper?.resume()
        sleeper = nil
    }
}

struct ReconnectCheck {
    typealias Failure = LoopbackCheck.CheckFailure
    let endpoint: URL

    func run() async throws {
        try await closeDuringFirstRetry()
        let clock = RetryClock()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let attempts = Mutex(0)
        let latest = Mutex<URLSessionWebSocketTask?>(nil)
        let size = Terminal.Size(columns: 16, rows: 3)
        let connection = TerminalWorker(size: size, sleepForRetry: { await clock.sleep(for: $0) }) { size in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            // The sixth retry returns a socket. This visits the cap twice.
            if (2...6).contains(attempt) { throw URLError(.notConnectedToInternet) }
            guard var url = URLComponents(url: endpoint.appending(path: "socket"), resolvingAgainstBaseURL: false) else {
                throw Failure("Invalid reconnect check endpoint")
            }
            url.scheme = "ws"
            url.queryItems = [
                .init(name: "service", value: "terminal"), .init(name: "clientId", value: "thrush lifecycle"),
                .init(name: "cols", value: String(size.columns)), .init(name: "rows", value: String(size.rows)),
            ]
            guard let address = url.url else { throw Failure("Invalid reconnect socket URL") }
            let task = session.webSocketTask(with: address)
            latest.withLock { $0 = task }
            return task
        }

        try await expect(.ready(resumed: false), from: connection)
        guard !(await connection.discardedHeldInputOnLastReady) else { throw Failure("Initial ready reported discarded input") }
        try await connection.send(.text("once"))
        try await expect(.output, from: connection)
        // The peer saw the first write. Cancel the task while the adapter still believes it is
        // active, so a second send takes URLSession's actual ambiguous-write failure path.
        latest.withLock { $0 }?.cancel(with: .goingAway, reason: nil)
        let (_, interrupted) = try await session.data(from: endpoint.appending(path: "check/interrupted"))
        guard (interrupted as? HTTPURLResponse)?.statusCode == 204 else { throw Failure("Peer did not observe socket loss") }
        let attemptsOnWire = Mutex<[String]>([])
        func mark(_ label: String) -> @Sendable () -> Void { { attemptsOnWire.withLock { $0.append(label) } } }
        let result: Void? = try? await connection.send(.text("ambiguous"), onWriteStarted: mark("ambiguous"))
        guard result == nil, attemptsOnWire.withLock({ $0 }) == ["ambiguous"] else {
            throw Failure("Expected an attempted write to fail on the canceled socket")
        }
        try await expect(.reconnecting, from: connection)
        try await connection.send(.key(.up), onWriteStarted: mark("up"))
        let emoji = String(repeating: "🪶", count: 16_384)
        try await reject(.paste(emoji + "x"), from: connection)
        // One grapheme can exceed the byte budget, even when Control would encode it as no bytes.
        let grapheme = Character("a" + String(repeating: "\u{301}", count: 32_768))
        try await reject(.key(.character(grapheme), modifiers: .control), from: connection)
        try await connection.send(.paste("a\nb"), onWriteStarted: mark("paste"))
        try await waitForResumedReady(connection)
        let schedule = [250, 500, 1_000, 2_000, 4_000, 4_000].map { Duration.milliseconds($0) }
        guard await clock.delays == schedule, !(await connection.replacedPreviousShell),
              !(await connection.discardedHeldInputOnLastReady) else {
            throw Failure("Incorrect retry backoff or a resumed shell was marked as replaced")
        }
        try await connection.send(.key(.left), onWriteStarted: mark("left"))
        guard attemptsOnWire.withLock({ $0 }) == ["ambiguous"] else { throw Failure("Held input wrote before replay") }
        try await expect(.output, from: connection) // Serialized application arrows and bracketed paste.
        try await expect(.output, from: connection) // Peer acknowledged all three re-encoded inputs.
        let delivered = ["ambiguous", "up", "paste", "left"]
        guard await connection.text(inRow: 0) == "ok", attemptsOnWire.withLock({ $0 }) == delivered else {
            throw Failure("Buffered input did not drain exactly once in order")
        }

        try await connection.send(.text("again"))
        try await expect(.reconnecting, from: connection)
        // Exactly 64 KiB of source bytes across two items. Fresh ready must discard both.
        try await connection.send(.text(String(emoji.dropLast())), onWriteStarted: mark("stale text"))
        try await connection.send(.paste("abcd"), onWriteStarted: mark("stale paste"))
        try await reject(.text("x"), from: connection)
        try await expect(.ready(resumed: false), from: connection)
        guard await connection.replacedPreviousShell, await connection.discardedHeldInputOnLastReady,
              await clock.delays == schedule + [.milliseconds(250)],
              attemptsOnWire.withLock({ $0 }) == delivered else {
            throw Failure("Fresh replacement or retry reset was missing after recovery")
        }
        try await connection.send(.text("clean"))
        try await expect(.output, from: connection)
        try await expect(.exit, from: connection)
        guard await connection.text(inRow: 0) == "done",
              !(await connection.attach()), await connection.attach(userInitiated: true) else {
            throw Failure("A natural exit must wait for an explicit restart")
        }
        try await expect(.ready(resumed: false), from: connection)
        guard !(await connection.replacedPreviousShell), !(await connection.discardedHeldInputOnLastReady) else {
            throw Failure("Explicit restart was marked as an unexpected replacement or input loss")
        }

        await clock.pauseNextSleep()
        try await connection.send(.text("pause"))
        try await expect(.reconnecting, from: connection)
        let waiting = Task { try await connection.nextEvent() }
        await clock.waitForSleeper()
        for _ in 0..<256 { try await connection.send(.key(.up)) }
        try await reject(.key(.up), from: connection)
        let attemptsBeforeDetach = attempts.withLock { $0 }
        await connection.detach()
        await clock.advance()
        guard case .failure = await waiting.result, await connection.state == .detached,
              attempts.withLock({ $0 }) == attemptsBeforeDetach else {
            throw Failure("A suspended retry accessed the transport after backgrounding")
        }
        try await reject(.text("background"), from: connection)
        guard await connection.attach() else { throw Failure("Foreground did not reattach") }
        try await expect(.ready(resumed: true), from: connection)
        try await expect(.output, from: connection)
        try await connection.send(.text("back")) // No held Up keys may precede this write.
        try await expect(.exit, from: connection)
    }

    private func closeDuringFirstRetry() async throws {
        let clock = RetryClock()
        let attempts = Mutex(0)
        let connection = TerminalWorker(size: nil, sleepForRetry: { await clock.sleep(for: $0) }) { _ in
            attempts.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        guard attempts.withLock({ $0 }) == 0, await connection.attach() else {
            throw Failure("Detached construction should wait for the first visible attach")
        }
        try await expect(.reconnecting, from: connection)
        await clock.pauseNextSleep()
        let pending = Task { try await connection.nextEvent() }
        await clock.waitForSleeper()
        let close: Void? = try? await connection.closeShell()
        await clock.advance()
        guard close == nil, case .failure = await pending.result, await connection.state == .ended,
              !(await connection.attach(userInitiated: true)), attempts.withLock({ $0 }) == 1 else {
            throw Failure("Offline explicit close must report the unsent control and permanently cancel retry")
        }
    }

    private func waitForResumedReady(_ connection: TerminalWorker) async throws {
        // A retry may announce another unavailable factory before the next pull.
        for _ in 0..<7 {
            let event = try await connection.nextEvent()
            if event == .ready(resumed: true) { return }
            guard event == .reconnecting else { throw Failure("Unexpected event during automatic recovery: \(event)") }
        }
        throw Failure("The resumed socket failed to become ready")
    }

    private func expect(_ expected: TerminalWorker.Event, from connection: TerminalWorker) async throws {
        let event = try await connection.nextEvent()
        guard event == expected else { throw Failure("Reconnect expected \(expected), received \(event)") }
    }

    private func reject(_ input: Terminal.Input, from connection: TerminalWorker) async throws {
        do { try await connection.send(input) }
        catch { return }
        throw Failure("An invalid reconnect write was accepted")
    }
}
