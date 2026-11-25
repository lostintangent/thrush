import ThrushCore

/// DEC synchronized output suppresses visible updates while the terminal keeps parsing.
/// Only released generations reach the view, including during unrelated layout or theme changes.
@MainActor
final class SynchronizedOutputGate {
    typealias Instant = ContinuousClock.Instant
    typealias Alarm = @MainActor (_ deadline: Instant, _ fire: @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

    private struct Frame {
        let snapshot: Terminal.Snapshot
        let receivedAt: Double?
    }

    private let now: @MainActor () -> Instant
    private let schedule: Alarm
    private let release: @MainActor (Terminal.Snapshot, Double?) -> Void

    private var active = true
    private var group: UInt64?
    private var deadline: Instant?
    private var held: Frame?
    private var ready: Frame?  // Most recent displayable frame received while inactive.
    private var cancelAlarm: (@MainActor () -> Void)?
    private var alarmRevision: UInt64 = 0

    init(now: @escaping @MainActor () -> Instant = { .now },
         schedule: @escaping Alarm = { deadline, fire in
             let task = Task { @MainActor in
                 do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                 guard !Task.isCancelled else { return }
                 fire()
             }
             return { task.cancel() }
         },
         release: @escaping @MainActor (Terminal.Snapshot, Double?) -> Void) {
        self.now = now
        self.schedule = schedule
        self.release = release
    }

    isolated deinit { cancelAlarm?() }

    func submit(_ snapshot: Terminal.Snapshot, receivedAt: Double?, synchronizedOutputID id: UInt64?) {
        let frame = Frame(snapshot: snapshot, receivedAt: receivedAt)
        if id != group {
            if id == nil {
                disarm()
                deadline = nil
                held = nil
            } else {
                // Repeated DECSET changes the ID but the pinned xterm keeps the
                // first watchdog running. A DECSET after expiry starts a new hold.
                serviceDeadline()
                if deadline == nil { deadline = now().advanced(by: .seconds(1)) }
            }
            group = id
        }
        guard deadline != nil else {
            publish(frame)
            return
        }
        held = frame
        serviceDeadline()
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        guard active else {
            disarm()
            return
        }
        // A long suspension may already have exhausted the original one-second budget.
        // Prefer that newer generation over a completed frame queued before its group began.
        serviceDeadline()
        if let ready { publish(ready) }
    }

    func reset() {
        disarm()
        group = nil
        deadline = nil
        held = nil
        ready = nil
    }

    private func publish(_ frame: Frame) {
        if active {
            ready = nil
            release(frame.snapshot, frame.receivedAt)
        } else {
            ready = frame
        }
    }

    private func serviceDeadline() {
        guard let deadline, let held else { return }
        if now() >= deadline {
            disarm()
            self.deadline = nil
            self.held = nil
            publish(held)
        } else if active, cancelAlarm == nil {
            let revision = alarmRevision
            cancelAlarm = schedule(deadline) { [weak self] in
                guard let self, self.alarmRevision == revision else { return }
                self.cancelAlarm = nil
                self.serviceDeadline()
            }
        }
    }

    private func disarm() {
        alarmRevision &+= 1
        cancelAlarm?()
        cancelAlarm = nil
    }
}
