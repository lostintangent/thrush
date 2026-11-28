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

/// Records each input write as it begins, including one whose delivery a socket loss leaves ambiguous.
private final class InputWrites: WebSocketFrameTrace {
    private let writes = Mutex<[String]>([])
    var all: [String] { writes.withLock { $0 } }

    func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                 note: String?, stale: Bool?, closeCode: Int?, received: Int?) {
        guard event == "input-write", case .data(let bytes) = message else { return }
        writes.withLock { $0.append(String(decoding: bytes, as: UTF8.self)) }
    }
}

struct ReconnectCheck {
    typealias Failure = LoopbackCheck.CheckFailure
    let endpoint: URL

    func run() async throws {
        try await closeDuringFirstRetry()
        let clock = RetryClock()
        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.invalidateAndCancel() }
        let attempts = Mutex(0)
        let latest = Mutex<URLSessionWebSocketTask?>(nil)
        let size = Terminal.Size(columns: 16, rows: 3)
        let makeSocket: @Sendable (Terminal.Size) throws -> URLSessionWebSocketTask = { size in
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
            let task = urlSession.webSocketTask(with: address)
            latest.withLock { $0 = task }
            return task
        }

        func open() -> SessionActor { SessionActor(size: size, sleepForRetry: { await clock.sleep(for: $0) }, makeSocket: makeSocket) }
        var session = open()
        try await expect(.ready(resumed: false), from: session)
        try await session.send(.text("once"))
        try await expect(.output, from: session)
        // The peer saw the first write. Cancel the task while the session still believes it is
        // active, so a second send takes URLSession's actual ambiguous-write failure path.
        latest.withLock { $0 }?.cancel(with: .goingAway, reason: nil)
        let (_, interrupted) = try await urlSession.data(from: endpoint.appending(path: "check/interrupted"))
        guard (interrupted as? HTTPURLResponse)?.statusCode == 204 else { throw Failure("Peer did not observe socket loss") }
        let writes = InputWrites()
        await session.trace(with: writes)
        let result: Void? = try? await session.send(.text("ambiguous"))
        guard result == nil, writes.all == ["ambiguous"] else {
            throw Failure("Expected an attempted write to fail on the canceled socket")
        }
        try await expect(.reconnecting, from: session)
        try await session.send(.key(.up))
        let emoji = String(repeating: "🪶", count: 16_384)
        try await reject(.paste(emoji + "x"), from: session)
        // One grapheme can exceed the byte budget, even when Control would encode it as no bytes.
        let grapheme = Character("a" + String(repeating: "\u{301}", count: 32_768))
        try await reject(.key(.character(grapheme), modifiers: .control), from: session)
        try await session.send(.paste("a\nb"))
        try await waitForResumedReady(session)
        let schedule = [250, 500, 1_000, 2_000, 4_000, 4_000].map { Duration.milliseconds($0) }
        guard await clock.delays == schedule else { throw Failure("Incorrect retry backoff") }
        try await session.send(.key(.left))
        guard writes.all == ["ambiguous"] else { throw Failure("Held input wrote before replay") }
        try await expect(.replay, from: session) // Serialized application arrows and bracketed paste.
        try await expect(.output, from: session) // Peer acknowledged all three re-encoded inputs.
        let delivered = ["ambiguous", "\u{1B}OA", "\u{1B}[200~a\rb\u{1B}[201~", "\u{1B}OD"]
        let editor = await session.snapshot()
        guard editor.isAlternate, editor.rows[0].text == "ok", editor.modes.applicationCursorKeys,
              editor.modes.bracketedPaste, await session.terminal.title == "Original shell",
              writes.all == delivered else {
            throw Failure("Buffered input did not drain exactly once in order")
        }

        try await session.send(.text("again"))
        try await expect(.reconnecting, from: session)
        // Exactly 64 KiB of source bytes across two items. Fresh ready must discard both.
        try await session.send(.text(String(emoji.dropLast())))
        try await session.send(.paste("abcd"))
        try await reject(.text("x"), from: session)
        try await expect(.replaced, from: session)
        let fresh = await session.snapshot()
        guard await session.state == .live, !fresh.isAlternate, !fresh.modes.applicationCursorKeys,
              !fresh.modes.bracketedPaste, await session.terminal.title.isEmpty,
              fresh.history.map(\.text).filter({ !$0.isEmpty }) == ["saved-main"], fresh.rows.allSatisfy({ $0.text.isEmpty }),
              await clock.delays == schedule + [.milliseconds(250)], writes.all == delivered + ["again"] else {
            throw Failure("Replacement must archive the main screen, reset shell state and discard its held input")
        }
        try await session.send(.text("clean"))
        try await expect(.output, from: session)
        guard await session.text(inRow: 0) == "new$ " else { throw Failure("Fresh prompt missed the first row") }
        try await expect(.output, from: session)
        try await expect(.ended, from: session)
        guard await session.text(inRow: 0) == "new$ clean",
              !(await session.show()), !(await session.show(userInitiated: true)) else {
            throw Failure("The old session restarted after natural exit")
        }
        session = open()
        try await expect(.ready(resumed: false), from: session)

        await clock.pauseNextSleep()
        try await session.send(.text("pause"))
        try await expect(.reconnecting, from: session)
        let waiting = Task { try await session.nextEvent() }
        await clock.waitForSleeper()
        for _ in 0..<256 { try await session.send(.key(.up)) }
        try await reject(.key(.up), from: session)
        let attemptsBeforeDetach = attempts.withLock { $0 }
        await session.hide()
        await clock.advance()
        guard case .failure = await waiting.result, await session.state == .idle,
              attempts.withLock({ $0 }) == attemptsBeforeDetach else {
            throw Failure("A suspended retry accessed the transport after backgrounding")
        }
        try await reject(.text("background"), from: session)
        guard await session.show() else { throw Failure("Foreground did not reattach") }
        try await expect(.ready(resumed: true), from: session)
        try await expect(.replay, from: session)
        try await session.send(.text("back")) // No held Up keys may precede this write.
        try await expect(.ended, from: session)
    }

    private func closeDuringFirstRetry() async throws {
        let clock = RetryClock()
        let attempts = Mutex(0)
        let session = SessionActor(size: nil, sleepForRetry: { await clock.sleep(for: $0) }) { _ in
            attempts.withLock { $0 += 1 }
            throw URLError(.notConnectedToInternet)
        }
        guard attempts.withLock({ $0 }) == 0, await session.show() else {
            throw Failure("An idle session should wait until first shown")
        }
        try await expect(.reconnecting, from: session)
        await clock.pauseNextSleep()
        let pending = Task { try await session.nextEvent() }
        await clock.waitForSleeper()
        let close: Void? = try? await session.closeShell()
        await clock.advance()
        guard close == nil, case .failure = await pending.result, await session.state == .ended,
              !(await session.show(userInitiated: true)), attempts.withLock({ $0 }) == 1 else {
            throw Failure("Offline explicit close must report the unsent control and permanently cancel retry")
        }
    }

    private func waitForResumedReady(_ session: SessionActor) async throws {
        // A retry may announce another unavailable factory before the next pull.
        for _ in 0..<7 {
            let event = try await session.nextEvent()
            if event == .ready(resumed: true) { return }
            guard event == .reconnecting else { throw Failure("Unexpected event during automatic recovery: \(event)") }
        }
        throw Failure("The resumed socket failed to become ready")
    }

    private func expect(_ expected: SessionActor.Event, from session: SessionActor) async throws {
        let event = try await session.nextEvent()
        guard event == expected else { throw Failure("Reconnect expected \(expected), received \(event)") }
    }

    private func reject(_ input: Terminal.Input, from session: SessionActor) async throws {
        do { try await session.send(input) }
        catch { return }
        throw Failure("An invalid reconnect write was accepted")
    }
}
