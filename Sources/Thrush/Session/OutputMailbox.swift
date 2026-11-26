import Synchronization
import ThrushCore

/// The session keeps reading while the main actor presents the latest ordinary output.
/// Rows travel as an immutable snapshot. The receipt belongs to the first update it includes.
final class OutputMailbox: Sendable {
    struct Frame: Sendable {
        let screen: Terminal.Snapshot
        let receipt: Double?
    }

    private struct State: Sendable {
        var frame: Frame?
        var notified = false
    }
    private let state = Mutex(State())

    /// Returns true when the view needs a wakeup. At most one wakeup can be queued.
    func offer(_ screen: Terminal.Snapshot, receivedAt receipt: Double?) -> Bool {
        state.withLock { state in
            let firstReceipt = state.frame == nil ? receipt : state.frame?.receipt
            state.frame = Frame(screen: screen, receipt: firstReceipt)
            guard !state.notified else { return false }
            state.notified = true
            return true
        }
    }

    /// A draw or an ordered control can take the frame before the queued wakeup arrives.
    func take(notification: Bool = false) -> Frame? {
        state.withLock { state in
            if notification { state.notified = false }
            defer { state.frame = nil }
            return state.frame
        }
    }
}
