import Foundation
import ThrushCore
import ThrushFixtures

/// Time only encoding. Verify each result against the recording before handing its bytes
/// to the independent reference runner, which opens a fresh terminal for each checkpoint.
func serializeCheckpoints(arguments: [String]) throws {
    guard arguments.count == 3 else { throw BenchmarkError("Usage: ThrushBench --serialize-replay FIXTURE OUTPUT") }
    let fixture = try ReplayFixture.decode(Data(contentsOf: URL(filePath: arguments[1])))
    var terminal = Terminal(size: .init(columns: fixture.columns, rows: fixture.rows))
    struct Sample: Encodable { let event: Int; let nanoseconds: UInt64; let bytes: Data }
    var results: [Sample] = []
    for (i, event) in fixture.events.enumerated() {
        event.applyReady(to: &terminal)
        if let size = event.resize { terminal.resize(to: .init(columns: size.columns, rows: size.rows)) }
        if let palette = event.palette { terminal.palette = palette }
        _ = terminal.receive(event.bytes)
        guard event.checkpoint != nil else { continue }
        let before = DispatchTime.now().uptimeNanoseconds
        let bytes = terminal.replayBytes()
        let elapsed = DispatchTime.now().uptimeNanoseconds - before
        var fresh = Terminal(size: terminal.size, palette: terminal.palette)
        // A restored focus mode answers with the new host's focus, which starts out.
        let focus = terminal.modes.sendFocus ? Array("\u{1b}[O".utf8) : []
        guard fresh.receive(bytes) == focus else { throw BenchmarkError("Replay produced an unexpected terminal reply at " + event.name) }
        try event.verify(fresh.snapshot(), serialized: true)
        results.append(Sample(event: i, nanoseconds: elapsed, bytes: Data(bytes)))
    }
    try JSONEncoder().encode(results).write(to: URL(filePath: arguments[2]), options: .atomic)
}
