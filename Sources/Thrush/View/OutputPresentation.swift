import QuartzCore
import ThrushCore

/// Gives adjacent output messages one presentation while the pane keeps reading the socket.
/// A sustained stream never extends the first message's deadline.
@MainActor
final class OutputPresentation {
    typealias Schedule = @MainActor (_ deadline: Double, _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    private let schedule: Schedule
    private let present: @MainActor (Terminal.Snapshot, Double?) -> Void
    private var pending: (screen: Terminal.Snapshot, receipt: Double)?
    private var cancel: (@MainActor () -> Void)?
    private var synchronized = false

    init(schedule: @escaping Schedule = { deadline, fire in
        let work = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: work)
        return { work.cancel() }
    }, present: @escaping @MainActor (Terminal.Snapshot, Double?) -> Void) {
        self.schedule = schedule
        self.present = present
    }

    isolated deinit { cancel?() }

    func submit(_ screen: Terminal.Snapshot, receivedAt receipt: Double?) {
        let wasSynchronized = synchronized
        synchronized = screen.synchronizedOutputID != nil
        guard !synchronized, !wasSynchronized, let receipt else {
            // Pass both edges of DEC synchronized output directly to the view's existing gate.
            flush()
            present(screen, receipt)
            return
        }
        let interval = 0.00025
        if let first = pending?.receipt, receipt < first + interval {
            pending = (screen, first)
            return
        }
        flush()
        pending = (screen, receipt)
        cancel = schedule(receipt + interval) { [weak self] in self?.flush() }
    }

    func flush() {
        guard let frame = pending else { return }
        cancel?()
        cancel = nil
        pending = nil
        present(frame.screen, frame.receipt)
    }

    func reset(synchronizedOutputID: UInt64? = nil) {
        cancel?()
        cancel = nil
        pending = nil
        synchronized = synchronizedOutputID != nil
    }
}
