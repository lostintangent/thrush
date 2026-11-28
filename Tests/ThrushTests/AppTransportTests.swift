import Foundation
import Synchronization
import Testing
import Thrush
import ThrushFixtures

// A one-use acknowledgement. The deadline only reports a missing callback.
private struct Acknowledgement: Sendable {
    private let signalStream = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func signal() {
        signalStream.continuation.yield(true)
        signalStream.continuation.finish()
    }

    func wait() async throws {
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            signalStream.continuation.yield(false)
            signalStream.continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = signalStream.stream.makeAsyncIterator()
        let received = await iterator.next()
        try #require(received == true)
    }
}

enum FailingTransportOperation: CaseIterable, Sendable { case write, resize }

actor ControlledTransport: TerminalTransport {
    enum Failure: Error { case interrupted }

    private let output = AsyncThrowingStream<Data, any Error>.makeStream()
    private(set) var writes: [Data] = []
    private(set) var closes = 0
    fileprivate nonisolated let closed = Acknowledgement()
    fileprivate nonisolated let reading = Acknowledgement()

    func read() async throws -> Data? {
        reading.signal()
        var iterator = output.stream.makeAsyncIterator()
        return try await iterator.next()
    }

    func emit(_ text: String) { output.continuation.yield(Data(text.utf8)) }
    func interrupt() { output.continuation.finish(throwing: Failure.interrupted) }
    private var failure: FailingTransportOperation?

    func fail(_ operation: FailingTransportOperation) { failure = operation }

    func write(_ bytes: Data) throws {
        // The remote end can receive bytes before the writer learns of a failure.
        writes.append(bytes)
        if failure == .write { throw Failure.interrupted }
    }

    private(set) var resizes: [Terminal.Size] = []

    func resize(to size: Terminal.Size) throws {
        resizes.append(size)
        if failure == .resize { throw Failure.interrupted }
    }
    func close() {
        closes += 1
        output.continuation.finish()
        closed.signal()
    }
}

// A factory that can still deliver its resource after its task is cancelled.
private actor DelayedOpen {
    nonisolated let started = Acknowledgement()
    private var result: CheckedContinuation<ControlledTransport, Never>?

    func open() async -> ControlledTransport {
        await withCheckedContinuation { continuation in
            result = continuation
            started.signal()
        }
    }

    func finish(with transport: ControlledTransport) {
        result?.resume(returning: transport)
        result = nil
    }
}

// Plays a recording at its original chunk boundaries, then reports EOF.
private actor RecordingTransport: TerminalTransport {
    private var chunks: [Data]
    private(set) var replies: [Data] = []

    init(_ chunks: [Data]) { self.chunks = chunks.reversed() }

    func read() -> Data? { chunks.popLast() }
    func write(_ bytes: Data) { replies.append(bytes) }
    func resize(to size: Terminal.Size) {}
    func close() {}
}

@MainActor @Test func appTransportPlaysTheFirstBytesToExit() async throws {
    let fixture = try FirstBytesFixture.load()
    let chunks = fixture.events.map { Data($0.bytes) }
    let size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)
    let transport = RecordingTransport(chunks)
    let opened = Mutex<[Terminal.Size]>([])
    let session = TerminalSession(openTransport: { size in
        opened.withLock { $0.append(size) }
        return transport
    })
    try await session.actor.sendResize(to: size)
    #expect(await session.actor.show())
    #expect(try await session.actor.nextEvent() == .ready(resumed: false))
    // Presentation may coalesce output while the session reads from the transport.
    var event: SessionActor.Event
    repeat { event = try await session.actor.nextEvent() } while event == .output

    #expect(event == .ended && session.hasEnded)
    #expect(opened.withLock { $0 } == [size])
    #expect(await session.actor.receivedBytes == chunks.reduce(0) { $0 + $1.count })
    #expect(await transport.replies == fixture.events.filter { !$0.reply.isEmpty }.map { Data($0.reply) })
    for (row, text) in fixture.events.reduce(into: [Int: String](), { $0[$1.row] = $1.text }) {
        #expect(await session.actor.text(inRow: row) == text)
    }
}

@MainActor @Test func closingDuringTransportOpenClosesTheLateTransport() async throws {
    let open = DelayedOpen()
    let transport = ControlledTransport()
    let session = TerminalSession(openTransport: { _ in await open.open() })
    let actor = session.actor
    try await actor.sendResize(to: .init(columns: 20, rows: 4))
    let opening = Task {
        if await actor.show() { _ = try? await actor.nextEvent() }
    }
    try await open.started.wait()

    let closed = Acknowledgement()
    let closing = Task { try await session.close(); closed.signal() }
    do {
        try await closed.wait()
    } catch {
        // Release the simulated non-cooperative factory even if close incorrectly waits for it.
        await open.finish(with: transport)
        throw error
    }
    try await closing.value
    #expect(session.hasEnded)
    await open.finish(with: transport)
    try await transport.closed.wait()
    await opening.value
    #expect(await transport.closes == 1)
    #expect(await actor.state == .ended)
    #expect(await actor.show(userInitiated: true) == false)
}

@MainActor @Test func interruptedTransportEndsItsSessionAndPreservesItsScreen() async throws {
    let first = ControlledTransport()
    let second = ControlledTransport()
    let sizes = Mutex<[Terminal.Size]>([])
    let session = TerminalSession(openTransport: { size in
        sizes.withLock { $0.append(size) }
        return first
    })
    let actor = session.actor
    let size = Terminal.Size(columns: 20, rows: 4)
    let cursor = Terminal.RGB(red: 29, green: 103, blue: 197)
    await actor.setPalette(.default, cursor: cursor)
    try await actor.sendResize(to: size)
    try #require(await actor.show())
    try #require(try await actor.nextEvent() == .ready(resumed: false))

    try await actor.send(.text("a"))
    await first.emit("tail\u{1b}[6n")
    try #require(try await actor.nextEvent() == .output)
    try await actor.send(.key(.enter))
    // The cursor query follows four printed cells. Replies and keystrokes use the same transport.
    #expect(await first.writes == [Data("a".utf8), Data("\u{1b}[1;5R".utf8), Data([13])])
    await first.interrupt()
    try #require(try await actor.nextEvent() == .ended)
    #expect(session.hasEnded)
    #expect(await actor.text(inRow: 0) == "tail")
    await actor.hide()
    #expect(await actor.show() == false)
    #expect(sizes.withLock { $0 } == [size])

    #expect(await actor.show(userInitiated: true) == false)
    #expect(sizes.withLock { $0 } == [size])
    let successor = TerminalSession(openTransport: { _ in second })
    try await successor.actor.sendResize(to: size)
    try #require(await successor.actor.show())
    try #require(try await successor.actor.nextEvent() == .ready(resumed: false))
    #expect(session.hasEnded && !successor.hasEnded)
    #expect(await actor.currentTerminal.cursorColor == cursor)
    #expect(await successor.actor.text(inRow: 0) == "")
    #expect(await second.writes.isEmpty)
    try await successor.close()
    #expect(await second.closes == 1)
}

@MainActor @Test func releasingHiddenSessionClosesItsPendingRead() async throws {
    let transport = ControlledTransport()
    var session: TerminalSession? = TerminalSession(openTransport: { _ in transport })
    weak let observedSession = session
    let actor = try #require(session?.actor)
    try await actor.sendResize(to: .init(columns: 20, rows: 4))
    try #require(await actor.show())
    try #require(try await actor.nextEvent() == .ready(resumed: false))
    try await transport.reading.wait()

    await actor.hide()
    #expect(await transport.closes == 0)
    session = nil
    #expect(observedSession == nil)
    try await transport.closed.wait()
    #expect(await transport.closes == 1)
}

@MainActor @Test(arguments: FailingTransportOperation.allCases)
func failedTransportOperationKeepsFinalOutputAndNeverRetries(_ operation: FailingTransportOperation) async throws {
    let first = ControlledTransport()
    let opens = Mutex(0)
    let session = TerminalSession(openTransport: { _ in
        opens.withLock { $0 += 1 }
        return first
    })
    let actor = session.actor
    try await actor.sendResize(to: .init(columns: 20, rows: 4))
    try #require(await actor.show())
    try #require(try await actor.nextEvent() == .ready(resumed: false))
    // Full-screen programs cannot redraw an alternate screen after the transport fails.
    let finalOutput = "\u{1b}[?1049hlast output"
    await first.emit(finalOutput)
    try #require(try await actor.nextEvent() == .output)
    await first.fail(operation)
    await #expect(throws: ControlledTransport.Failure.interrupted) {
        switch operation {
        case .write: try await actor.send(.text("uncertain"))
        case .resize: try await actor.sendResize(to: .init(columns: 6, rows: 4))
        }
    }
    try #require(try await actor.nextEvent() == .ended)
    #expect(await actor.text(inRow: 0) == "last output")
    #expect(await actor.receivedBytes == finalOutput.utf8.count)
    #expect(await first.writes == (operation == .write ? [Data("uncertain".utf8)] : []))
    #expect(await first.closes == 1)
    #expect(session.hasEnded)
    #expect(await actor.show() == false)
    #expect(opens.withLock { $0 } == 1)

    #expect(await actor.show(userInitiated: true) == false)
    #expect(opens.withLock { $0 } == 1)
}

@MainActor @Test func hiddenAppShellHearsEachAppearanceFlip() async throws {
    let transport = ControlledTransport()
    let session = TerminalSession(openTransport: { _ in transport })
    let actor = session.actor
    let dark = TerminalTheme.dark, light = TerminalTheme.light
    await actor.setPalette(dark.palette, cursor: dark.cursor)
    try await actor.sendResize(to: .init(columns: 20, rows: 4))
    try #require(await actor.show())
    try #require(try await actor.nextEvent() == .ready(resumed: false))
    await transport.emit("\u{1b}[?2031h")
    try #require(try await actor.nextEvent() == .output)

    // An app transport keeps reading while its pane is hidden, so its shell stays current.
    await actor.hide()
    await actor.setPalette(light.palette, cursor: light.cursor)
    await actor.setPalette(light.palette, cursor: light.cursor)
    #expect(await transport.writes == [Data("\u{1b}[?997;2n".utf8)])
}
