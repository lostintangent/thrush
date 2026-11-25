import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Paces SGR 5 blinking text. Every pane follows the same media clock, so all blinking text
/// fades out and back in together. A view draws only during the two fades of each cycle and
/// holds its frame in between. It draws nothing for blinking once no visible text blinks.
@MainActor
package final class TextBlink {
    /// One cycle is 1.2 seconds, a slow blink of 50 per minute. ECMA-48 allows fewer than 150.
    package nonisolated static let shown = 0.5, fadeOut = 0.2, hidden = 0.3, fadeIn = 0.2
    package nonisolated static let period = shown + fadeOut + hidden + fadeIn

    /// The opacity of blinking text presented at `time` on the media clock.
    nonisolated static func opacity(at time: Double) -> Float {
        func ease(_ progress: Double) -> Float {
            let t = min(max(progress, 0), 1)
            return Float(t * t * (3 - 2 * t))
        }
        let phase = time.truncatingRemainder(dividingBy: period)
        if phase < shown { return 1 }
        if phase < shown + fadeOut { return 1 - ease((phase - shown) / fadeOut) }
        if phase < period - fadeIn { return 0 }
        return ease((phase - period + fadeIn) / fadeIn)
    }

    /// `time` itself during a fade, otherwise the start of the next fade.
    nonisolated static func nextFade(from time: Double) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period)
        let cycle = time - phase
        if phase < shown { return cycle + shown }
        if phase < shown + fadeOut { return time }
        if phase < period - fadeIn { return cycle + period - fadeIn }
        return time
    }

    private let redraw: @MainActor () -> Void
    private var link: CADisplayLink?
    private var wake: Task<Void, Never>?
    /// The latest tick's target, so a fade's final frame lands exactly on the steady opacity.
    private var target = 0.0
    /// The opacity of the latest frame the pacer requested.
    private var drawn: Float = 1

    init(redraw: @escaping @MainActor () -> Void) {
        self.redraw = redraw
    }

    isolated deinit { stop() }

    /// The opacity of blinking text in a frame drawn now.
    var opacity: Float { Self.opacity(at: max(CACurrentMediaTime(), target)) }

    var isRunning: Bool { link != nil }

    /// Follow a drawn frame. Pace the fades while it shows blinking text, otherwise stop.
    func frameDrawn(blinking: Bool, in view: TerminalView) {
        guard blinking else { return stop() }
        guard link == nil else { return }
        let tick = Tick(owner: self)
        #if os(macOS)
        let link = view.displayLink(target: tick, selector: #selector(Tick.fire(_:)))
        #else
        guard let link = view.window?.windowScene?.displayLink(target: tick, selector: #selector(Tick.fire(_:))) else { return }
        #endif
        // An opacity fade looks smooth at 60 Hz. ProMotion would spend twice the frames.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        let now = CACurrentMediaTime()
        drawn = Self.opacity(at: now)
        hold(until: Self.nextFade(from: now))
    }

    func stop() {
        wake?.cancel()
        wake = nil
        link?.invalidate()
        link = nil
        target = 0
    }

    fileprivate func fire(_ link: CADisplayLink) {
        target = link.targetTimestamp
        let opacity = Self.opacity(at: target)
        if opacity != drawn {
            drawn = opacity
            redraw()
        }
        let next = Self.nextFade(from: target)
        if next > target {
            link.isPaused = true
            hold(until: next)
        }
    }

    private func hold(until start: Double) {
        wake?.cancel()
        let delay = start - CACurrentMediaTime()
        guard delay > 0 else {
            link?.isPaused = false
            return
        }
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(4))
            guard !Task.isCancelled else { return }
            self?.link?.isPaused = false
        }
    }
}

/// A display link retains its target, so this forwards each tick without retaining the pacer.
@MainActor
private final class Tick: NSObject {
    weak var owner: TextBlink?

    init(owner: TextBlink) { self.owner = owner }

    @objc func fire(_ link: CADisplayLink) {
        guard let owner else { return link.invalidate() }
        owner.fire(link)
    }
}
