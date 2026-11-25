import Dispatch
import ThrushCore

/// Receive throughput timed over spans far longer than the clock's 42 ns tick. Each sample
/// replays a recording on enough fresh terminals to apply at least 8 KiB, one terminal at
/// a time, so a recording of a few bytes is timed as accurately as a long one. The rate
/// comes from the median sample.
struct ReceiveRate {
    /// The output between two state changes, and the change applied before it.
    struct Span {
        var change: ((inout Terminal) -> Void)?
        var chunks: [ArraySlice<UInt8>] = []
    }

    static let samples = 25
    static let minimumBytesPerSample = 8 * 1024

    let replaysPerSample: Int
    let mebibytesPerSecond: Double

    init(size: Terminal.Size, spans: [Span]) {
        let bytesPerReplay = spans.reduce(0) { total, span in span.chunks.reduce(total) { $0 + $1.count } }
        let replays = (Self.minimumBytesPerSample + bytesPerReplay - 1) / bytesPerReplay
        let times = (0..<Self.samples).map { _ in
            var terminals = (0..<replays).map { _ in Terminal(size: size) }
            var elapsed: UInt64 = 0
            // The clock stops while every terminal applies a change, such as a resize.
            for span in spans {
                if let change = span.change {
                    for index in terminals.indices { change(&terminals[index]) }
                }
                let start = DispatchTime.now().uptimeNanoseconds
                for index in terminals.indices {
                    for chunk in span.chunks { _ = terminals[index].receive(chunk) }
                }
                elapsed += DispatchTime.now().uptimeNanoseconds - start
            }
            return elapsed
        }
        replaysPerSample = replays
        // The median sample keeps a burst of host contention from moving the rate.
        let median = times.sorted()[Self.samples / 2]
        mebibytesPerSecond = ThrushBench.mebibytesPerSecond(replays * bytesPerReplay, in: median)
    }
}
