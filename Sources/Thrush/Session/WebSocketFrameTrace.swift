import Foundation

/// Package-only diagnostics for checks and the demo's disposable native workflow, installed with
/// `SessionActor.trace(with:)`. Events include each received message, its acceptance and
/// application, lifecycle changes and the beginning of each input and control write. An observer
/// must return promptly because terminal reads and parser application stay on the session actor.
package protocol WebSocketFrameTrace: Sendable {
    func observe(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message?,
                 note: String?, stale: Bool?, closeCode: Int?, received: Int?, applied: Int?)
}

extension WebSocketFrameTrace {
    func record(_ event: String, attachment: Int, message: URLSessionWebSocketTask.Message? = nil,
                note: String? = nil, stale: Bool? = nil, closeCode: Int? = nil,
                received: Int? = nil, applied: Int? = nil) {
        observe(event, attachment: attachment, message: message, note: note, stale: stale,
                closeCode: closeCode, received: received, applied: applied)
    }
}
