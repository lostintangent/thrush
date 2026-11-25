import Foundation
import Thrush
import ThrushFixtures

/// Supplies the recording at its original chunk boundaries and captures the terminal's replies.
private actor FixtureTransport: TerminalTransport {
    let chunks: [Data]
    private var index = 0
    private(set) var replies: [Data] = []
    private var started: UInt64 = 0
    private(set) var elapsed: UInt64?

    init(_ chunks: [Data]) { self.chunks = chunks }

    func read() -> Data? {
        if index == 0 { started = DispatchTime.now().uptimeNanoseconds }
        guard index < chunks.count else {
            elapsed = DispatchTime.now().uptimeNanoseconds - started
            return nil
        }
        defer { index += 1 }
        return chunks[index]
    }

    func write(_ bytes: Data) { replies.append(bytes) }
    func resize(to size: Terminal.Size) {}
    func close() {}
}

extension LoopbackCheck {
    @MainActor
    static func measureAppTransport() async throws {
        let fixture = try FirstBytesFixture.load()
        let chunks = fixture.events.map { Data($0.bytes) }
        let replies = fixture.events.filter { !$0.reply.isEmpty }.map { Data($0.reply) }
        let expectedBytes = chunks.reduce(0) { $0 + $1.count }
        let finalRows = fixture.events.reduce(into: [Int: String]()) { $0[$1.row] = $1.text }
        let size = Terminal.Size(columns: fixture.columns, rows: fixture.rows)

        func pass() async throws -> UInt64 {
            let transport = FixtureTransport(chunks)
            let session = TerminalSession(openTransport: { grid in
                guard grid == size else { throw CheckFailure("The stream opened at an unexpected size.") }
                return transport
            })
            try await session.actor.sendResize(to: size)
            guard await session.actor.show(), try await session.actor.nextEvent() == .ready(resumed: false) else {
                throw CheckFailure("The app transport did not open.")
            }
            // Presentation may coalesce output while the session reads from the transport.
            var event: SessionActor.Event
            repeat { event = try await session.actor.nextEvent() } while event == .output
            guard event == .exit, session.hasEnded, let elapsed = await transport.elapsed,
                  await session.actor.receivedBytes == expectedBytes, await session.actor.appliedBytes == expectedBytes,
                  await transport.replies == replies else {
                throw CheckFailure("Stream bytes, replies or EOF differed from the recording.")
            }
            for (row, text) in finalRows {
                guard await session.actor.text(inRow: row) == text else { throw CheckFailure("Incorrect final row \(row).") }
            }
            return elapsed
        }

        _ = try await pass()
        var samples: [UInt64] = []
        for _ in 0..<5 { samples.append(try await pass()) }
        print(String(decoding: try JSONEncoder().encode(samples), as: UTF8.self))
    }
}
