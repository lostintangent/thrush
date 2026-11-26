import Dispatch
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// When program output draws. A program often writes one change in several pieces a fraction of
/// a millisecond apart, and a frame drawn between them would show part of the change for a whole
/// refresh. So output draws once per refresh, after its writes pause and as late as still makes
/// that refresh: by the display's next refresh less the time a frame has recently needed. Echo
/// takes the same path and reaches the screen on the refresh an immediate draw would have made.
struct FrameSchedule {
    /// How long output must pause before its frame draws, so the pieces of one change share it.
    static let quiet = 0.001
    /// Room for the timer's wakeup and for the compositor to pick up a finished frame.
    static let slack = 0.001

    /// The latest refresh the display link reported.
    private(set) var refresh: Double?
    /// The measured time between refreshes. It averages over every refresh since `epoch`, so a
    /// paused link still predicts refreshes on the display's own cadence.
    private(set) var interval = 1.0 / 60
    private var epoch: Double?
    /// The slowest recent frame, from when it was due until its GPU work ended. It rises to a
    /// slower frame at once and settles back over about ten frames.
    private(set) var cost = 0.002

    /// How long before a refresh its frame must start. It never takes more than three quarters of a refresh.
    var margin: Double { min(cost + Self.slack, interval * 0.75) }

    /// Follows a display link tick. A new refresh rate or a beat off the measured cadence starts a
    /// new measurement.
    mutating func observe(target: Double, duration: Double) {
        if duration > 0, abs(duration - interval) > interval / 20 {
            interval = duration
            epoch = nil
        }
        if let epoch {
            let refreshes = ((target - epoch) / interval).rounded()
            if abs(target - epoch - refreshes * interval) >= interval / 4 {
                self.epoch = target
            } else if refreshes >= 1 {
                interval = (target - epoch) / refreshes
            }
        } else {
            epoch = target
        }
        refresh = target
    }

    /// The first refresh that a frame starting at `now` still makes and that comes after the
    /// refresh `drawn` already has a frame for. It's nil until the display link reports a refresh.
    func refresh(after now: Double, past drawn: Double?) -> Double? {
        guard let refresh else { return nil }
        let earliest = max(now + margin, (drawn ?? -.infinity) + interval / 2)
        return refresh + max(0, ((earliest - refresh) / interval).rounded(.down) + 1) * interval
    }

    /// When the frame for `refresh` draws, given the latest output arrived at `output`: once
    /// output pauses, but not before the previous refresh's deadline and not after its own.
    func drawTime(for refresh: Double, output: Double) -> Double {
        let deadline = refresh - margin
        return min(max(deadline - interval, output + Self.quiet), deadline)
    }

    /// Follows a frame's cost. A frame slower than a refresh couldn't make one at any margin.
    mutating func drew(cost sample: Double) {
        guard sample.isFinite, sample > 0 else { return }
        let sample = min(sample, interval)
        cost = sample > cost ? sample : cost + (sample - cost) / 8
    }
}

/// Runs a view's one display link only while something needs its ticks, and draws program
/// output when the schedule says. Output needs ticks until the first refresh after it arrives,
/// which keeps the schedule current, and blinking text needs them during its fades. A view
/// that's idle, hidden or outside a window has no running link and draws nothing.
@MainActor
final class FramePacer {
    private(set) var schedule = FrameSchedule()
    /// Whether blinking text is fading and needs every tick.
    var isFading = false {
        didSet { if oldValue != isFading { updateLink() } }
    }
    /// When the output frame in progress was due, so its cost includes any wait past that.
    private(set) var due: Double?

    private unowned let view: TerminalView
    private let drawOutput: @MainActor () -> Void
    private let fadeTick: @MainActor (Double) -> Void
    private var link: CADisplayLink?
    private var linkFollowsOutput: Bool?
    private var timer: DispatchSourceTimer?
    /// The refresh that waiting output draws for.
    private var pending: Double?
    /// The refresh the latest frame was drawn for. The compositor shows each frame for at least
    /// one refresh, so a second frame for the same refresh would show a refresh late.
    private var drawn: Double?
    private var lastOutput = 0.0
    /// Output arrived since the last tick, so the link runs until the next one.
    private var awaitingTick = false

    init(view: TerminalView, drawOutput: @escaping @MainActor () -> Void,
         fadeTick: @escaping @MainActor (Double) -> Void) {
        self.view = view
        self.drawOutput = drawOutput
        self.fadeTick = fadeTick
    }

    isolated deinit {
        link?.invalidate()
        timer?.cancel()
    }

    /// Schedules newly arrived output. It returns false before the link has reported a refresh,
    /// and the caller draws now.
    func outputChanged() -> Bool {
        lastOutput = CACurrentMediaTime()
        awaitingTick = true
        updateLink()
        if let pending {
            arm(schedule.drawTime(for: pending, output: lastOutput))
            return true
        }
        guard let refresh = schedule.refresh(after: lastOutput, past: drawn) else { return false }
        pending = refresh
        arm(schedule.drawTime(for: refresh, output: lastOutput))
        return true
    }

    /// Follows a submitted frame, which includes all waiting output.
    func drew() {
        drawn = pending ?? schedule.refresh(after: CACurrentMediaTime(), past: drawn)
        cancel()
    }

    func record(cost: Double) { schedule.drew(cost: cost) }

    /// Drops the link and its refreshes, so the next link follows the view's current window and display.
    func reattach() {
        link?.invalidate()
        link = nil
        schedule = FrameSchedule()
        drawn = nil
        updateLink()
    }

    /// Forgets waiting output and stops ticking. The view draws its latest state when it shows again.
    func stop() {
        cancel()
        awaitingTick = false
        link?.invalidate()
        link = nil
    }

    private func cancel() {
        guard pending != nil else { return }
        pending = nil
        timer?.schedule(deadline: .distantFuture)
    }

    private func arm(_ time: Double) {
        let timer = self.timer ?? {
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.fire() }
            }
            timer.activate()
            self.timer = timer
            return timer
        }()
        // Dispatch uptime and the media clock both count host time since boot.
        let nanoseconds = UInt64(max(time, 0) * 1_000_000_000)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: nanoseconds), leeway: .microseconds(50))
    }

    private func fire() {
        guard let pending else { return }
        let time = schedule.drawTime(for: pending, output: lastOutput)
        // More output arrived since the timer was set, so wait for it to pause.
        if time > CACurrentMediaTime() + 0.0001 { return arm(time) }
        due = time
        drawOutput()
        due = nil
        // A frame that couldn't draw, such as with three already in flight, draws when one completes.
        self.pending = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        schedule.observe(target: link.targetTimestamp, duration: link.targetTimestamp - link.timestamp)
        awaitingTick = false
        if let pending {
            let now = CACurrentMediaTime()
            if schedule.drawTime(for: pending, output: lastOutput) <= now {
                // The main thread was busy past the draw time, so the frame draws now.
                fire()
            } else if let refresh = schedule.refresh(after: now, past: drawn) {
                // A paused link predicted the refresh. Place it on the display's actual cadence.
                self.pending = refresh
                arm(schedule.drawTime(for: refresh, output: lastOutput))
            }
        }
        if isFading { fadeTick(link.targetTimestamp) }
        updateLink()
    }

    private func updateLink() {
        let output = pending != nil || awaitingTick
        guard output || isFading else {
            link?.isPaused = true
            return
        }
        if link == nil {
            let tick = Tick(owner: self)
            #if os(macOS)
            link = view.displayLink(target: tick, selector: #selector(Tick.fire(_:)))
            #else
            link = view.window?.windowScene?.displayLink(target: tick, selector: #selector(Tick.fire(_:)))
            #endif
            link?.add(to: .main, forMode: .common)
            linkFollowsOutput = nil
        }
        guard let link else { return }
        if linkFollowsOutput != output {
            linkFollowsOutput = output
            // Output follows the display's own rate. An opacity fade looks smooth at 60 Hz, and
            // ProMotion would spend twice the frames.
            link.preferredFrameRateRange = output ? .default : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
        link.isPaused = false
    }
}

/// A display link retains its target, so this forwards each tick without retaining the pacer.
@MainActor
private final class Tick: NSObject {
    weak var owner: FramePacer?

    init(owner: FramePacer) { self.owner = owner }

    @objc func fire(_ link: CADisplayLink) {
        guard let owner else { return link.invalidate() }
        owner.tick(link)
    }
}
