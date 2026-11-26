import CryptoKit
import Foundation
import QuartzCore
import Thrush

/// Exercise DEC synchronized output at the native view boundary, after the ordinary draw workloads.
@MainActor
enum SynchronizedRenderCheck {
    struct Release: Encodable {
        let expectedGeneration: UInt64
        let generation: UInt64
        let receivedAt: Double
        let submittedAt: Double
        var presentedTime: Double?
        let submissions: Int
    }

    struct Result: Encodable {
        let workloadSHA256: String
        let holdOpenedAt: Double
        let heldGenerations: [UInt64]
        let submissionsDuringHold: Int
        let close: Release
        let truncatedOpenedAt: Double
        let watchdog: Release
        let watchdogToSubmissionSeconds: Double
        let idle: RenderBenchmark.IdleObservation
    }

    private struct Update {
        let generation: UInt64
        let receipt: Double
    }

    static func run(on view: TerminalMetalView, continuing previous: Terminal, frames: RenderFrameObservations) async throws -> Result {
        var terminal = previous
        var hash = SHA256()
        let begin = "\u{1b}[?2026h"
        let end = "\u{1b}[?2026l"
        let rewrite = "\u{1b}[1;1H\u{1b}[K"
        func feed(_ text: String) -> Update {
            let bytes = Array(text.utf8)
            hash.update(data: bytes)
            let receipt = CACurrentMediaTime()
            _ = terminal.write(bytes)
            let snapshot = terminal.snapshot()
            view.display(snapshot, receivedAt: receipt)
            return Update(generation: snapshot.generation, receipt: receipt)
        }

        func collect(_ update: Update, since count: Int) async throws -> Release {
            let frame = try await frames.frame(for: "synchronized output", generation: update.generation,
                                               after: update.receipt, receivedAt: update.receipt, initialSubmissions: count)
            return Release(expectedGeneration: update.generation, generation: frame.generation,
                           receivedAt: update.receipt, submittedAt: frame.submittedAt, presentedTime: nil,
                           submissions: view.submissionCount - count)
        }

        // A completed normal frame separates the foreground return from the first measured group.
        let initial = view.submissionCount
        _ = try await collect(feed(rewrite + "ready"), since: initial)
        let before = view.submissionCount
        let first = feed(begin + rewrite + "partial")
        try await Task.sleep(for: .milliseconds(50))
        let second = feed(rewrite + "replaced")
        let third = feed(begin + rewrite + "last partial")
        try await Task.sleep(for: .milliseconds(50))
        let partials = view.submissionCount - before
        let closing = feed(rewrite + "complete" + end)
        var close = try await collect(closing, since: before + partials)

        // Omit DECRST. The latest receipt belongs to the text chunk, while the one-second
        // watchdog is measured from the first open. submittedAt includes native draw scheduling.
        let beforeTruncated = view.submissionCount
        let truncated = feed(begin + rewrite + "unfinished")
        try await Task.sleep(for: .milliseconds(50))
        let final = feed(rewrite + "watchdog")
        var watchdog = try await collect(final, since: beforeTruncated)
        let idleCount = view.submissionCount
        let idleStart = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(1))
        let idle = RenderBenchmark.IdleObservation(seconds: CACurrentMediaTime() - idleStart,
                                                  additionalSubmissions: view.submissionCount - idleCount)
        close.presentedTime = try frames.presentationTime(for: close.submittedAt)
        watchdog.presentedTime = try frames.presentationTime(for: watchdog.submittedAt)
        let watchdogDelay = watchdog.submittedAt - truncated.receipt
        let result = Result(workloadSHA256: hash.finalize().map { String(format: "%02x", $0) }.joined(),
                            holdOpenedAt: first.receipt, heldGenerations: [first.generation, second.generation, third.generation],
                            submissionsDuringHold: partials, close: close, truncatedOpenedAt: truncated.receipt,
                            watchdog: watchdog, watchdogToSubmissionSeconds: watchdogDelay, idle: idle)
        guard closing.receipt - first.receipt < 1, partials == 0, close.submissions == 1,
              watchdogDelay >= 1, watchdog.submissions == 1, idle.additionalSubmissions == 0 else {
            throw RenderBenchmark.Failure("Synchronized output submitted \(partials) partial, \(close.submissions) closing, "
                + "\(watchdog.submissions) timeout and \(idle.additionalSubmissions) idle frames. "
                + "Closing hold lasted \(closing.receipt - first.receipt) s, watchdog submission took \(watchdogDelay) s.")
        }
        return result
    }
}
