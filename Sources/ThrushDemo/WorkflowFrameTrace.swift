import Foundation
import QuartzCore
import Synchronization
import Thrush

/// Development-only native frame evidence for the finite, disposable lifecycle workflow.
/// Formatting and disk I/O run off the session actor.
final class WorkflowFrameTrace: WebSocketFrameTrace {
    private let records: Mutex<Records>

    init(url: URL) throws { records = try Mutex(Records(url: url)) }

    /// New app sessions start their counters at zero. The workflow trace covers the whole exchange.
    func continuing(after attachments: Int, received: Int) -> any WebSocketFrameTrace {
        SessionTrace(trace: self, attachments: attachments, received: received)
    }

    private struct SessionTrace: WebSocketFrameTrace {
        let trace: WorkflowFrameTrace
        let attachments, received: Int

        func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                     note: String?, stale: Bool?, closeCode: Int?, received: Int?) {
            trace.observe(event, attachment: attachments + attachment, message: message, note: note, stale: stale,
                          closeCode: closeCode, received: received.map { self.received + $0 })
        }
    }

    func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                 note: String?, stale: Bool?, closeCode: Int?, received: Int?) {
        records.withLock {
            $0.record(event, attachment: attachment, message: message, note: note, stale: stale,
                      closeCode: closeCode, received: received)
        }
    }

    func finish(_ result: String, attachment: Int, received: Int) async {
        let writer = records.withLock { records in
            records.finish(result, attachment: attachment, received: received)
            return records.writer
        }
        // Publish the footer before the report or error file releases the launcher.
        await withCheckedContinuation { done in writer.async { done.resume() } }
    }
}

private struct Records: Sendable {
    private struct Record: Encodable, Sendable {
        let sequence: Int
        let monotonicMs: Double, wallUnixMs: Double?
        let attachment: Int, frame: Int?
        let event: String
        let length: Int?, hex: String?, text: String?
        let stale: Bool?, closeCode: Int?
        let receivedBytes: Int?
    }

    private final class Output: Sendable {
        let queue = DispatchQueue(label: "Thrush.lifecycle-frame-trace")
        let file: FileHandle

        init(url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
            file = try FileHandle(forWritingTo: url)
        }
    }

    private let output: Output
    var writer: DispatchQueue { output.queue }
    private var sequence = 0
    private var payloadBytes = 0
    private var frames: [Int: Int] = [:]
    private var truncated = false
    private var finished = false

    init(url: URL) throws { output = try Output(url: url) }

    mutating func record(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message? = nil,
                         note: String? = nil, stale: Bool? = nil, closeCode: Int? = nil,
                         received: Int? = nil) {
        guard !finished, !truncated else { return }
        var data: Data?
        var text = note
        switch message {
        case .data(let bytes): data = bytes
        case .string(let string): text = string
        default: break
        }
        let length = data?.count ?? text?.utf8.count
        guard sequence < 8_192, (length ?? 0) <= 1_048_576 - payloadBytes else {
            truncated = true
            append("truncated", attachment: attachment)
            return
        }
        payloadBytes += length ?? 0
        if event == "observed" { frames[attachment, default: 0] += 1 }
        // Frame numbers count received messages, so a write has none.
        let frame = message != nil && !event.hasSuffix("-write") ? frames[attachment] : nil
        append(event, attachment: attachment, frame: frame, data: data, text: text, length: length,
               stale: stale, closeCode: closeCode, received: received)
    }

    mutating func finish(_ result: String, attachment: Int, received: Int) {
        guard !finished else { return }
        finished = true
        append("finished", attachment: attachment, text: result, received: received)
    }

    private mutating func append(_ event: String, attachment: Int, frame: Int? = nil, data: Data? = nil,
                                 text: String? = nil, length: Int? = nil, stale: Bool? = nil,
                                 closeCode: Int? = nil, received: Int? = nil) {
        sequence += 1
        let time = CACurrentMediaTime() * 1_000
        let wall = event == "open" ? Date().timeIntervalSince1970 * 1_000 : nil
        output.queue.async { [output, sequence] in
            let alphabet = Array("0123456789abcdef".utf8)
            let hex = data.map { bytes in
                String(decoding: bytes.flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }, as: UTF8.self)
            }
            let record = Record(sequence: sequence, monotonicMs: time, wallUnixMs: wall, attachment: attachment, frame: frame,
                                event: event, length: length, hex: hex, text: text, stale: stale, closeCode: closeCode,
                                receivedBytes: received)
            do {
                var line = try JSONEncoder().encode(record)
                line.append(10)
                try output.file.write(contentsOf: line)
            } catch {
                FileHandle.standardError.write(Data("Lifecycle frame trace: \(error)\n".utf8))
            }
        }
    }
}
