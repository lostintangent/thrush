import Foundation
import Synchronization
import Thrush

/// A lagging but connected host gets one new snapshot on its existing socket. Input continues
/// using the visible grid's modes while the peer is holding the serialized binary frame.
struct InBandReplayCheck {
    typealias Failure = LoopbackCheck.CheckFailure
    let endpoint: URL

    func run() async throws {
        let size = Terminal.Size(columns: 16, rows: 3)
        let resized = Terminal.Size(columns: 17, rows: 3)
        let defaults = Terminal.Palette.default
        let palette = Terminal.Palette(foreground: defaults.background, background: defaults.foreground, ansi: defaults.ansi)
        let observed = Mutex<[Data]>([])
        let session = try SessionActor(baseURL: endpoint, clientID: "thrush lifecycle", size: size,
                                       palette: palette) { bytes in observed.withLock { $0.append(bytes) } }
        guard try await session.nextEvent() == .ready(resumed: false),
              try await session.nextEvent() == .output else { throw Failure("Missing output before in-band replay") }
        let old = await session.snapshot()
        guard old.history.map(\.text) == ["gone"], old.rows.map(\.text) == ["old 1", "old 2", "old 3"],
              old.modes.applicationCursorKeys, !old.modes.bracketedPaste else { throw Failure("Incorrect pre-stall grid") }

        let repair = Task { try await session.nextEvent() }
        defer { repair.cancel() }
        // Wait for the actor to consume the in-band ready. The HTTP barrier below controls when
        // the peer sends the promised replay. No wall-clock delay determines wire order.
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await session.awaitingReplay) {
            guard ContinuousClock.now < deadline else { throw Failure("In-band ready never began receiving the replay") }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await session.sendResize(to: resized)
        try await session.send(.key(.up))
        let visible = await session.snapshot()
        guard await session.state == .active, visible.size == size, visible.palette == palette,
              visible.generation == old.generation, visible.modes == old.modes,
              visible.cursorColumn == old.cursorColumn, visible.cursorRow == old.cursorRow,
              visible.history.map(\.text) == old.history.map(\.text),
              visible.rows.map(\.text) == old.rows.map(\.text) else {
            throw Failure("The active screen changed before the promised in-band replay arrived")
        }

        let (_, response) = try await URLSession.shared.data(from: endpoint.appending(path: "check/live-replay"))
        guard (response as? HTTPURLResponse)?.statusCode == 204,
              try await repair.value == .replay else { throw Failure("Expected exactly one replay event") }
        let restored = await session.snapshot()
        guard await session.state == .active, !(await session.awaitingReplay),
              restored.palette == palette, restored.size == resized,
              restored.history.map(\.text) == ["oldest", "newer"], restored.rows.map(\.text) == ["one", "two", "three"],
              restored.cursorRow == 2, restored.cursorColumn == 5,
              !restored.modes.applicationCursorKeys, restored.modes.bracketedPaste else {
            throw Failure("In-band replay failed to replace the old history, partial OSC, cursor or input modes")
        }
        guard try await session.nextEvent() == .output, await session.text(inRow: 2) == "three!" else {
            throw Failure("Live output must follow the complete repaired screen exactly once")
        }
        try await session.send(.key(.up))
        try await session.send(.paste("a\nb"))
        guard try await session.nextEvent() == .output, await session.text(inRow: 2) == "bye",
              try await session.nextEvent() == .exit, await session.state == .ended,
              !(await session.show()), (try? await session.nextEvent()) == nil else {
            throw Failure("Final bytes and exit must survive the immediately following normal socket close")
        }

        let frames = [
            "gone\r\nold 1\r\nold 2\r\nold 3\u{1b}[?1h\u{1b}]0;partial",
            "oldest\r\nnewer\r\none\r\ntwo\r\nthree\u{1b}[?2004h", "!", "\r\nbye",
        ].map { Data($0.utf8) }
        let bytes = frames.reduce(0) { $0 + $1.count }
        guard observed.withLock({ $0 }) == frames, await session.receivedBytes == bytes,
              await session.appliedBytes == bytes else { throw Failure("Dropped or duplicated replay or live bytes") }

        for invalid in ["in-band fresh ready", "duplicate ready without a replay"] {
            let rejected = try SessionActor(baseURL: endpoint, clientID: "thrush lifecycle", size: size)
            guard try await rejected.nextEvent() == .ready(resumed: false), try await rejected.nextEvent() == .output,
                  (try? await rejected.nextEvent()) == nil, await rejected.state == .idle,
                  !(await rejected.awaitingReplay), await rejected.text(inRow: 0) == "kept" else {
                throw Failure("Invalid \(invalid) must stop the attachment and preserve its last screen")
            }
        }
    }
}
