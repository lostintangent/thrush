import Foundation
import Synchronization
import Testing
import Thrush

// A one-use acknowledgement. The deadline only reports a missing callback.
private struct Acknowledgement: Sendable {
    private let channel = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func signal() {
        channel.continuation.yield(true)
        channel.continuation.finish()
    }

    func wait() async throws {
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            channel.continuation.yield(false)
            channel.continuation.finish()
        }
        defer { timeout.cancel() }
        var iterator = channel.stream.makeAsyncIterator()
        let received = await iterator.next()
        try #require(received == true)
    }
}

enum FailingStreamOperation: CaseIterable, Sendable { case write, resize }

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
    private var failure: FailingStreamOperation?

    func fail(_ operation: FailingStreamOperation) { failure = operation }

    func write(_ bytes: Data) throws {
        // The remote end can receive bytes before the writer learns of a failure.
        writes.append(bytes)
        if failure == .write { throw Failure.interrupted }
    }

    func resize(to size: Terminal.Size) throws {
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

    func finish(with channel: ControlledTransport) {
        result?.resume(returning: channel)
        result = nil
    }
}

@MainActor @Test func closingDuringTransportOpenDisposesTheLateChannel() async throws {
    let open = DelayedOpen()
    let channel = ControlledTransport()
    let session = TerminalSession(openTransport: { _ in await open.open() })
    let worker = session.worker
    try await worker.sendResize(to: .init(columns: 20, rows: 4))
    let opening = Task {
        if await worker.attach() { _ = try? await worker.nextEvent() }
    }
    try await open.started.wait()

    let closed = Acknowledgement()
    let closing = Task { try await session.close(); closed.signal() }
    do {
        try await closed.wait()
    } catch {
        // Release the simulated non-cooperative factory even if close incorrectly waits for it.
        await open.finish(with: channel)
        throw error
    }
    try await closing.value
    #expect(session.hasEnded)
    await open.finish(with: channel)
    try await channel.closed.wait()
    await opening.value
    #expect(await channel.closes == 1)
    #expect(await worker.state == .ended)
    #expect(await worker.attach(userInitiated: true) == false)
}

@MainActor @Test func interruptedTransportPreservesItsScreenUntilExplicitRestart() async throws {
    let first = ControlledTransport()
    let second = ControlledTransport()
    let sizes = Mutex<[Terminal.Size]>([])
    let session = TerminalSession(openTransport: { size in
        sizes.withLock { attempts in
            attempts.append(size)
            return attempts.count == 1 ? first : second
        }
    })
    let worker = session.worker
    let size = Terminal.Size(columns: 20, rows: 4)
    try await worker.sendResize(to: size)
    try #require(await worker.attach())
    try #require(try await worker.nextEvent() == .ready(resumed: false))

    try await worker.send(.text("a"))
    await first.emit("tail\u{1b}[6n")
    try #require(try await worker.nextEvent() == .output)
    try await worker.send(.key(.enter))
    // The cursor query follows four printed cells. Replies and keystrokes share the byte stream.
    #expect(await first.writes == [Data("a".utf8), Data("\u{1b}[1;5R".utf8), Data([13])])
    await first.interrupt()
    try #require(try await worker.nextEvent() == .exit)
    #expect(session.hasEnded)
    #expect(await worker.text(inRow: 0) == "tail")
    await worker.detach()
    #expect(await worker.attach() == false)
    #expect(sizes.withLock { $0 } == [size])

    try #require(await worker.attach(userInitiated: true))
    try #require(try await worker.nextEvent() == .ready(resumed: false))
    #expect(!session.hasEnded)
    #expect(await worker.text(inRow: 0) == "")
    #expect(await second.writes.isEmpty)
    #expect(sizes.withLock { $0 } == [size, size])
    try await session.close()
    #expect(await worker.attach(userInitiated: true) == false)
    #expect(await second.closes == 1)
}

@MainActor @Test func releasingHiddenSessionClosesItsPendingRead() async throws {
    let channel = ControlledTransport()
    var session: TerminalSession? = TerminalSession(openTransport: { _ in channel })
    weak let observedSession = session
    let worker = try #require(session?.worker)
    try await worker.sendResize(to: .init(columns: 20, rows: 4))
    try #require(await worker.attach())
    try #require(try await worker.nextEvent() == .ready(resumed: false))
    try await channel.reading.wait()

    await worker.detach()
    #expect(await channel.closes == 0)
    session = nil
    #expect(observedSession == nil)
    try await channel.closed.wait()
    #expect(await channel.closes == 1)
}

@MainActor @Test(arguments: FailingStreamOperation.allCases)
func failedTransportOperationKeepsFinalOutputAndNeverRetries(_ operation: FailingStreamOperation) async throws {
    let first = ControlledTransport()
    let replacement = ControlledTransport()
    let opens = Mutex(0)
    let session = TerminalSession(openTransport: { _ in
        opens.withLock { count in
            count += 1
            return count == 1 ? first : replacement
        }
    })
    let worker = session.worker
    try await worker.sendResize(to: .init(columns: 20, rows: 4))
    try #require(await worker.attach())
    try #require(try await worker.nextEvent() == .ready(resumed: false))
    // Full-screen programs cannot redraw an alternate screen after the channel fails.
    let finalOutput = "\u{1b}[?1049hlast output"
    await first.emit(finalOutput)
    try #require(try await worker.nextEvent() == .output)
    await first.fail(operation)
    await #expect(throws: ControlledTransport.Failure.interrupted) {
        switch operation {
        case .write: try await worker.send(.text("uncertain"))
        case .resize: try await worker.sendResize(to: .init(columns: 6, rows: 4))
        }
    }
    try #require(try await worker.nextEvent() == .exit)
    #expect(await worker.text(inRow: 0) == "last output")
    #expect(await worker.appliedBytes == finalOutput.utf8.count)
    #expect(await first.writes == (operation == .write ? [Data("uncertain".utf8)] : []))
    #expect(await first.closes == 1)
    #expect(session.hasEnded)
    #expect(await worker.attach() == false)
    #expect(opens.withLock { $0 } == 1)

    try #require(await worker.attach(userInitiated: true))
    try #require(try await worker.nextEvent() == .ready(resumed: false))
    try await worker.send(.text("new"))
    #expect(await replacement.writes == [Data("new".utf8)])
    try await session.close()
}
