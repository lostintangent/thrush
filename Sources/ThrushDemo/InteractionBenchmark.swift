import Foundation
import QuartzCore
import Thrush
import ThrushUI

/// One native view, one socket and one echoed marker at a time. A new key is issued only after
/// both the remote bytes and their matching Metal submission have been observed.
@MainActor
final class InteractionBenchmark {
    private struct Sample: Encodable {
        let marker: String
        let generation: UInt64
        let keyAt: Double
        let sentAt: Double
        let receivedAt: Double
        let submittedAt: Double?
        let presentedAt: Double?
    }

    private struct Report: Encodable {
        let schemaVersion = 1
        let recordedAt = Date()
        let environment: RenderEnvironment
        let columns: Int
        let rows: Int
        let displayIntervalSeconds: Double?
        let committedEcho: String
        let copiedText: String
        let historyReadingLine: String
        let selectionAndCopyMilliseconds: Double
        let historyScrollMilliseconds: Double
        let returnToLatestMilliseconds: Double
        let keyToSendP95Milliseconds: Double
        let keyToReceiptP95Milliseconds: Double
        let receiptToPresentationP95Milliseconds: Double?
        let keyToVisibleEchoP95Milliseconds: Double?
        let samples: [Sample]
    }

    private let view: TerminalView
    private var sentAt: Double?
    private var receipt: (generation: UInt64, time: Double)?
    private var frame: FrameMeasurement?

    init(view: TerminalView) { self.view = view }

    func writeStarted(at time: Double) { sentAt = time }
    func received(generation: UInt64, at time: Double) { receipt = (generation, time) }

    func run(reportURL: URL) async throws {
        guard let size = view.gridSize else { throw RenderBenchmark.Failure("Missing native grid.") }
        let previous = view.onFrame
        view.onFrame = { [weak self] frame in
            previous?(frame)
            if frame.receivedAt != nil { self?.frame = frame }
        }
        defer { view.onFrame = previous }
        let probe = try NativeInteractionProbe(view: view)
        // Wait for the keyboard/layout-guide transition before recording the run's viewport.
        try await Task.sleep(for: .milliseconds(450))
        let grid = view.gridSize ?? size
        let interval = try? await DisplayInterval.measure(on: view)
        let initial = probe.transcript
        let composition = "翼"
        try probe.mark("つばさ")
        try probe.mark(composition)
        guard probe.transcript == initial else { throw RenderBenchmark.Failure("Marked text escaped into the transcript.") }
        _ = try await echo(marker: composition, expectedSuffix: composition, probe: probe) {
            try probe.commit(composition)
        }
        let suffix = " " + String(repeating: "a soft wrap ", count: 8) + "ends here."
        let known = composition + suffix
        _ = try await echo(marker: "paste", expectedSuffix: known, probe: probe) { try probe.paste(suffix) }

        let all = probe.transcript
        guard let range = all.range(of: known) else { throw RenderBenchmark.Failure("Missing soft-wrapped marker.") }
        let startCopy = CACurrentMediaTime()
        try probe.select(NSRange(range, in: all), in: all)
        guard probe.selection == known else { throw RenderBenchmark.Failure("The copied text differs from the input.") }
        let copyMilliseconds = (CACurrentMediaTime() - startCopy) * 1_000

        let startHistory = CACurrentMediaTime()
        view.setHistoryOffset(6)
        guard view.historyOffset == 6, let reading = probe.readLine(0), !reading.isEmpty else {
            throw RenderBenchmark.Failure("Unable to read the expected history viewport.")
        }
        let historyMilliseconds = (CACurrentMediaTime() - startHistory) * 1_000
        let startLatest = CACurrentMediaTime()
        try probe.latest()
        guard view.historyOffset == 0, probe.transcript == all else {
            throw RenderBenchmark.Failure("Latest did not restore the live viewport.")
        }
        let latestMilliseconds = (CACurrentMediaTime() - startLatest) * 1_000

        var samples = [Sample]()
        var expected = known
        for marker in "abcdefghijklmnopqrst".map(String.init) {
            expected.append(marker)
            let sample = try await echo(marker: marker, expectedSuffix: expected, probe: probe) {
                try probe.commit(marker)
            }
            samples.append(sample)
        }
        func p95(_ times: [Double]) -> Double? {
            guard !times.isEmpty else { return nil }
            return times.sorted()[max(0, Int(ceil(0.95 * Double(times.count))) - 1)] * 1_000
        }
        // Report visible-echo distributions only for a complete set of observed presentations.
        let allPresented = samples.allSatisfy { $0.presentedAt != nil }
        let report = Report(environment: .init(), columns: grid.columns, rows: grid.rows,
                            displayIntervalSeconds: interval, committedEcho: composition, copiedText: known,
                            historyReadingLine: reading, selectionAndCopyMilliseconds: copyMilliseconds,
                            historyScrollMilliseconds: historyMilliseconds, returnToLatestMilliseconds: latestMilliseconds,
                            keyToSendP95Milliseconds: p95(samples.map { $0.sentAt - $0.keyAt })!,
                            keyToReceiptP95Milliseconds: p95(samples.map { $0.receivedAt - $0.keyAt })!,
                            receiptToPresentationP95Milliseconds: allPresented ? p95(samples.compactMap { s in s.presentedAt.map { $0 - s.receivedAt } }) : nil,
                            keyToVisibleEchoP95Milliseconds: allPresented ? p95(samples.compactMap { s in s.presentedAt.map { $0 - s.keyAt } }) : nil,
                            samples: samples)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        print("ThrushBench interactions   \(grid.columns) × \(grid.rows)   \(samples.count) echoed keys")
        print("Report \(reportURL.path)")
    }

    private func echo(marker: String, expectedSuffix: String, probe: NativeInteractionProbe,
                      action: () throws -> Void) async throws -> Sample {
        sentAt = nil
        receipt = nil
        frame = nil
        let keyAt = CACurrentMediaTime()
        try action()
        let deadline = keyAt + 10
        while CACurrentMediaTime() < deadline {
            if let sentAt, let receipt,
               probe.transcript.trimmingCharacters(in: .newlines).hasSuffix(expectedSuffix) {
                let matched = frame.flatMap { measurement in
                    measurement.generation == receipt.generation && measurement.receivedAt == receipt.time ? measurement : nil
                }
                // A sleeping display can deliver the wire echo with no drawable. Give the
                // normal draw path a chance to finish and retain those samples as unavailable.
                if matched != nil || CACurrentMediaTime() - receipt.time >= 0.35 {
                    guard keyAt <= sentAt, sentAt <= receipt.time,
                          matched.map({ $0.submittedAt >= receipt.time }) ?? true,
                          matched.flatMap({ frame in frame.presentedTime.map { $0 >= frame.submittedAt } }) ?? true else {
                        throw RenderBenchmark.Failure("Nonmonotonic timing for \(marker).")
                    }
                    return Sample(marker: marker, generation: receipt.generation, keyAt: keyAt, sentAt: sentAt,
                                  receivedAt: receipt.time, submittedAt: matched?.submittedAt, presentedAt: matched?.presentedTime)
                }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw RenderBenchmark.Failure("Missing socket write, echo transcript, or matching native frame for \(marker).")
    }
}
