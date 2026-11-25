import Foundation

/// Package-only diagnostics for a disposable native workflow. An observer must return promptly
/// from receive observations so terminal reads and parser application stay on the same actor.
package protocol ConnectionFrameObserver: Sendable {
    func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                 note: String?, stale: Bool?, closeCode: Int?, received: Int?, applied: Int?)
    func finish(_ result: String, attachment: Int, received: Int, applied: Int) async
}

extension ConnectionFrameObserver {
    func record(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message? = nil,
                note: String? = nil, stale: Bool? = nil, closeCode: Int? = nil,
                received: Int? = nil, applied: Int? = nil) {
        observe(event, attachment: attachment, message: message, note: note, stale: stale,
                closeCode: closeCode, received: received, applied: applied)
    }
}
