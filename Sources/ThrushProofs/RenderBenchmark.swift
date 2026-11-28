import CryptoKit
import Darwin
import Foundation
import QuartzCore
import Thrush
#if os(macOS)
import AppKit
import IOKit.ps
#else
import UIKit
#endif

/// Exercise the installed package's renderer in its native window, using its normal draw path.
@MainActor
enum RenderBenchmark {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    struct Sample: Encodable {
        let operation: String
        var frame: FrameMeasurement

        var receiptToPresentation: Double? {
            guard let presented = frame.presentedTime, let received = frame.receivedAt else { return nil }
            return presented - received
        }
    }

    private struct Workload: Encodable {
        let operation: String
        let frames: Int
        let unpresented: Int
        let cpuP50Milliseconds: Double?
        let cpuP95Milliseconds: Double?
        let gpuP95Milliseconds: Double?
        let receiptToPresentationP95Milliseconds: Double?
        let glyphUploads: Int
        let maximumRowsPrepared: Int
        let overTwoDisplayIntervals: Int
    }

    struct IdleObservation: Encodable {
        let seconds: Double
        let additionalSubmissions: Int
    }

    /// Blinking text submits frames only during its fades, and none under Reduce Motion
    /// or once the text stops blinking.
    private struct BlinkObservation: Encodable {
        let seconds: Double
        let submissions: Int
        let minimumSubmissions: Int
        let maximumSubmissions: Int
        let rowsPrepared: Int
        let glyphUploads: Int
        let reducedMotion: IdleObservation
        let steady: IdleObservation
    }

    private struct ThemeSwitch: Encodable {
        let theme: String
        var frame: FrameMeasurement
    }

    private struct Report: Encodable {
        let schemaVersion = 6
        let recordedAt: Date
        let workloadSHA256: String
        let environment: RenderEnvironment
        let columns: Int
        let rows: Int
        let displayIntervalSeconds: Double
        let samples: [Sample]
        let workloads: [Workload]
        let themeSwitches: [ThemeSwitch]
        let foregroundIdle: IdleObservation
        let textBlink: BlinkObservation
        let inactiveRenderer: IdleObservation
        let background: IdleObservation
        let synchronizedOutput: SynchronizedRenderCheck.Result
    }

    private static func quantile(_ values: [Double], _ q: Double) -> Double? {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return nil }
        return ordered[max(0, Int(ceil(q * Double(ordered.count))) - 1)]
    }

    private static func summarize(_ samples: [Sample], interval: Double) -> [Workload] {
        let operations = ["cold", "cursor", "oneRow", "scroll", "full"]
        return operations.map { operation in
            let matching = samples.filter { $0.operation == operation }
            let cpu = matching.map { $0.frame.cpuPreparationSeconds * 1_000 }
            let gpu = matching.compactMap(\.frame.gpuSeconds).map { $0 * 1_000 }
            let latency = matching.compactMap(\.receiptToPresentation)
            return Workload(operation: operation, frames: matching.count,
                            unpresented: matching.count - latency.count,
                            cpuP50Milliseconds: quantile(cpu, 0.5),
                            cpuP95Milliseconds: quantile(cpu, 0.95),
                            gpuP95Milliseconds: quantile(gpu, 0.95),
                            receiptToPresentationP95Milliseconds: quantile(latency.map { $0 * 1_000 }, 0.95),
                            glyphUploads: matching.map(\.frame.glyphUploads).reduce(0, +),
                            maximumRowsPrepared: matching.map(\.frame.rowsPrepared).max() ?? 0,
                            overTwoDisplayIntervals: latency.filter { $0 > 2 * interval }.count)
        }
    }

    static func run(on view: TerminalMetalView, size: Terminal.Size, reportURL: URL) async throws {
        #if DEBUG
        throw Failure("Build the packaged proofs app in Release to measure rendering.")
        #else
        guard size.columns >= 24, size.rows >= 2 else { throw Failure("Render benchmark needs at least 24 × 2.") }
        let frames = RenderFrameObservations(view: view)
        defer { frames.stop() }
        let collector = FrameCollector(view: view, size: size, frames: frames)
        view.reset()
        // Keep the same glyphs and styles for every warm frame. Neither cursor motion nor
        // reflow to a different viewport is allowed to hide the cost of a new glyph upload.
        let line = "\u{1b}[36mA翼🐦Z\u{1b}[0m 0123456789"
        let full = (1...size.rows).map { "\u{1b}[\($0);1H" + line }.joined() + "\u{1b}[1;1H"
        try await collector.apply("\u{1b}[?12l" + full, as: "cold")
        let interval = try await DisplayInterval.measure(on: view)
        let environment = RenderEnvironment()
        let first = collector.terminal.snapshot().rows[0]
        guard first[0].text == "A", first[1].text == "翼", first[1].width == 2, first[2].width == 0,
              first[3].text == "🐦", first[3].width == 2, first[4].width == 0, first[5].text == "Z"
        else { throw Failure("The wide text checkpoint did not occupy six cells.") }

        for _ in 0..<10 {
            try await collector.apply("\u{1b}[1;6H", as: "cursor")
            try await collector.apply("\u{1b}[1;9H89", as: "oneRow")
            try await collector.apply("\u{1b}[\(size.rows);1H\r\n" + line, as: "scroll")
            try await collector.apply(full, as: "full")
        }
        let originalTheme = view.theme
        let selection = TerminalMetalView.Selection(anchorRow: 0, anchorColumn: 1, headRow: 0, headColumn: 4)
        try await collector.observeMutation { view.selection = selection }
        var alternate = TerminalTheme.dark
        alternate.cursor = .init(red: 0x82, green: 0xCB, blue: 0xC5)
        let firstTheme: TerminalTheme = view.resolvedTheme == .dark ? .light : .dark
        let secondTheme: TerminalTheme = firstTheme == .dark ? .light : .dark
        let themes = [firstTheme, secondTheme, alternate]
        var switches: [ThemeSwitch] = []
        for theme in themes {
            let frame = try await collector.observeMutation { view.theme = theme }
            guard view.selection == selection, view.resolvedTheme == theme, view.gridSize == size else {
                throw Failure("Changing appearance displaced the selection or resized the grid.")
            }
            let name = theme == .dark ? "Dark" : theme == .light ? "Light" : "Custom"
            switches.append(.init(theme: name, frame: frame))
        }
        try await collector.observeMutation {
            view.theme = originalTheme
            view.selection = nil
        }
        let foregroundIdle = try await observeIdle(view)
        let textBlink = try await observeBlink(collector, interval: interval)
        view.setDrawingVisible(false)
        // Hide the drawing as a covered or background view does. Keep an update pending,
        // so a renderer that merely suppresses its timer fails this check.
        let inactive: IdleObservation
        let before = view.submissionCount
        let start = CACurrentMediaTime()
        _ = collector.terminal.write("\u{1b}[1;3H".utf8)
        view.display(collector.terminal)
        try await Task.sleep(for: .seconds(1))
        inactive = IdleObservation(seconds: CACurrentMediaTime() - start,
                                   additionalSubmissions: view.submissionCount - before)

        let workloadSHA256 = collector.hash.finalize().hexString
        view.setDrawingVisible(true)
        // A return from the inactive probe may submit its pending generation. Wait for
        // it before observing the operating system's own transition.
        try await collector.apply("\u{1b}[1;6H", as: "restore")
        let background = try await RenderLifecycleObserver(view: view).measure(reportURL: reportURL) {
            _ = collector.terminal.write("\u{1b}[1;3H".utf8)
            view.display(collector.terminal)
        }

        let synchronizedOutput = try await SynchronizedRenderCheck.run(on: view, continuing: collector.terminal, frames: frames)
        var samples = collector.samples.filter { $0.operation != "restore" }
        for i in samples.indices { samples[i].frame = try frames.presented(samples[i].frame) }
        for i in switches.indices { switches[i].frame = try frames.presented(switches[i].frame) }
        let workloads = summarize(samples, interval: interval)
        let report = Report(recordedAt: Date(), workloadSHA256: workloadSHA256,
                            environment: environment, columns: size.columns, rows: size.rows,
                            displayIntervalSeconds: interval, samples: samples, workloads: workloads,
                            themeSwitches: switches, foregroundIdle: foregroundIdle, textBlink: textBlink,
                            inactiveRenderer: inactive,
                            background: background, synchronizedOutput: synchronizedOutput)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (encoder.encode(report) + Data([0x0A])).write(to: reportURL, options: .atomic)
        print("Render   \(size.columns) × \(size.rows)   \(environment.hardwareModel)   \(environment.commit.prefix(12))")
        print("Load \(environment.loadAverage)   \(environment.coreCount) cores   contended \(environment.contended)   thermal \(environment.thermalState)")
        print("Operation   frames   CPU p95 ms   GPU p95 ms   receipt → presentation p95 ms   uploads   max rows")
        func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "unavailable" }
        for work in workloads {
            print("\(work.operation)   \(work.frames)   \(milliseconds(work.cpuP95Milliseconds))   \(milliseconds(work.gpuP95Milliseconds))   \(milliseconds(work.receiptToPresentationP95Milliseconds))   \(work.glyphUploads)   \(work.maximumRowsPrepared)")
        }
        if let compile = samples.first?.frame.shaderCompileSeconds, let first = samples.first?.frame.firstFrameSeconds {
            print(String(format: "Runtime shader compile %.3f ms   first content submission %.3f ms", compile * 1_000, first * 1_000))
        }
        print("Additional submissions   settled \(foregroundIdle.additionalSubmissions)   inactive \(inactive.additionalSubmissions)   background \(background.additionalSubmissions)")
        print(String(format: "Blinking text   %d submissions in %.3f s, allowed %d to %d   %d rows   %d uploads   Reduce Motion %d   steady %d",
                     textBlink.submissions, textBlink.seconds, textBlink.minimumSubmissions, textBlink.maximumSubmissions,
                     textBlink.rowsPrepared, textBlink.glyphUploads, textBlink.reducedMotion.additionalSubmissions,
                     textBlink.steady.additionalSubmissions))
        print(String(format: "Synchronized output   %d partial   %d close   watchdog submission %.3f ms   %d idle",
                     synchronizedOutput.submissionsDuringHold, synchronizedOutput.close.submissions,
                     synchronizedOutput.watchdogToSubmissionSeconds * 1000, synchronizedOutput.idle.additionalSubmissions))
        print("Report \(reportURL.path)")
        guard foregroundIdle.additionalSubmissions == 0, inactive.additionalSubmissions == 0,
              (textBlink.minimumSubmissions...textBlink.maximumSubmissions).contains(textBlink.submissions),
              textBlink.rowsPrepared == 0, textBlink.glyphUploads == 0,
              textBlink.reducedMotion.additionalSubmissions == 0, textBlink.steady.additionalSubmissions == 0,
              background.additionalSubmissions == 0,
              switches.allSatisfy({ $0.frame.rowsPrepared == 0 && $0.frame.glyphUploads == 0 }),
              samples[0].frame.glyphUploads > 0, samples[0].frame.rowsPrepared == size.rows,
              samples.dropFirst().allSatisfy({ $0.frame.glyphUploads == 0 }),
              samples.filter({ ["oneRow", "cursor"].contains($0.operation) }).allSatisfy({ $0.frame.rowsPrepared <= 1 }),
              samples.filter({ $0.operation == "full" }).allSatisfy({ $0.frame.rowsPrepared == size.rows })
        else { throw Failure("Draw cache, atlas warmup, blink pacing or settled frame checkpoint failed. See \(reportURL.path).") }
        #endif
    }

    private static func observeIdle(_ view: TerminalMetalView, for seconds: Double = 1) async throws -> IdleObservation {
        let before = view.submissionCount
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(seconds))
        return IdleObservation(seconds: CACurrentMediaTime() - start, additionalSubmissions: view.submissionCount - before)
    }

    /// Blinks digits the warm rounds already uploaded, then restores them. The bytes stay
    /// outside the hashed workload, and the screen afterwards matches the screen before.
    private static func observeBlink(_ collector: FrameCollector, interval: Double) async throws -> BlinkObservation {
        let view = collector.view
        let systemSetting = view.reducesMotion
        view.reducesMotion = false
        defer { view.reducesMotion = systemSetting }
        try await collector.show("\u{1b}[1;8H\u{1b}[5m0123\u{1b}[0m\u{1b}[1;1H")
        let before = view.submissionCount
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(2 * TextBlink.period))
        let seconds = CACurrentMediaTime() - start
        let submissions = view.submissionCount - before
        let blinkFrames = collector.frames.completions(since: start)
        // The pacer draws at up to 60 Hz during the fades, plus the frame that ends each one.
        // Fewer than 10 frames a second would no longer read as a fade.
        let cycles = seconds / TextBlink.period
        let fading = cycles * (TextBlink.fadeOut + TextBlink.fadeIn)
        let minimum = Int(fading * 10)
        let maximum = Int((fading * min(1 / interval, 60)).rounded(.up)) + 2 * Int(cycles.rounded(.up)) + 1
        try await collector.observeMutation { view.reducesMotion = true }
        let reducedMotion = try await observeIdle(view, for: TextBlink.period)
        view.reducesMotion = false
        try await collector.show("\u{1b}[1;8H0123\u{1b}[1;1H")
        let steady = try await observeIdle(view, for: TextBlink.period)
        return BlinkObservation(seconds: seconds, submissions: submissions, minimumSubmissions: minimum,
                                maximumSubmissions: maximum,
                                rowsPrepared: blinkFrames.map(\.rowsPrepared).reduce(0, +),
                                glyphUploads: blinkFrames.map(\.glyphUploads).reduce(0, +),
                                reducedMotion: reducedMotion, steady: steady)
    }

    @MainActor
    private final class FrameCollector {
        let view: TerminalMetalView
        let frames: RenderFrameObservations
        var terminal: Terminal
        var hash = SHA256()
        var samples: [Sample] = []

        init(view: TerminalMetalView, size: Terminal.Size, frames: RenderFrameObservations) {
            self.view = view
            self.frames = frames
            terminal = Terminal(size: size)
        }

        @discardableResult
        func observeMutation(_ mutation: () -> Void) async throws -> FrameMeasurement {
            let start = CACurrentMediaTime()
            let initialSubmissions = view.submissionCount
            let generation = terminal.snapshot().generation
            mutation()
            return try await frames.frame(for: "viewport or theme change", generation: generation, after: start,
                                          initialSubmissions: initialSubmissions)
        }

        /// Draws bytes that belong to no measured workload.
        func show(_ string: String) async throws {
            let start = CACurrentMediaTime()
            _ = terminal.write(string.utf8)
            let initialSubmissions = view.submissionCount
            view.display(terminal)
            _ = try await frames.frame(for: "blink setup", generation: terminal.snapshot().generation, after: start,
                                       initialSubmissions: initialSubmissions)
        }

        func apply(_ string: String, as operation: String) async throws {
            let bytes = Array(string.utf8)
            hash.update(data: bytes)
            let receipt = CACurrentMediaTime()
            _ = terminal.write(bytes)
            let expected = terminal.snapshot().generation
            let initialSubmissions = view.submissionCount
            view.display(terminal, receivedAt: receipt)
            let frame = try await frames.frame(for: operation, generation: expected, after: receipt,
                                               receivedAt: receipt, initialSubmissions: initialSubmissions)
            samples.append(Sample(operation: operation, frame: frame))
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

@MainActor
final class DisplayInterval: NSObject {
    private var periods: [Double] = []

    @objc private func tick(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0, interval.isFinite { periods.append(interval) }
    }

    static func measure(on view: TerminalMetalView) async throws -> Double {
        let sample = DisplayInterval()
        #if os(macOS)
        let link = view.displayLink(target: sample, selector: #selector(tick(_:)))
        #else
        guard let link = view.window?.windowScene?.displayLink(target: sample, selector: #selector(tick(_:))) else {
            throw RenderBenchmark.Failure("No active scene display link.")
        }
        #endif
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        let deadline = CACurrentMediaTime() + 10
        while sample.periods.count < 12 {
            guard CACurrentMediaTime() < deadline else { throw RenderBenchmark.Failure("No active display interval.") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let ordered = sample.periods.sorted()
        return ordered[ordered.count / 2]
    }
}

struct RenderEnvironment: Encodable {
    let commit: String
    let worktreeDirty: Bool
    let toolchain: String
    let hardwareModel: String
    let operatingSystem: String
    let destination: String
    let coreCount: Int
    let loadAverage: [Double]
    let contended: Bool
    let thermalState: String
    let lowPowerMode: Bool
    let powerSource: String

    @MainActor init() {
        let info = ProcessInfo.processInfo
        let bundle = Bundle.main
        commit = bundle.object(forInfoDictionaryKey: "ThrushGitCommit") as? String ?? "unknown"
        worktreeDirty = bundle.object(forInfoDictionaryKey: "ThrushWorktreeDirty") as? Bool ?? true
        toolchain = bundle.object(forInfoDictionaryKey: "ThrushToolchain") as? String ?? "unknown"
        operatingSystem = info.operatingSystemVersionString
        coreCount = info.activeProcessorCount
        var load = Array(repeating: 0.0, count: 3)
        let available = getloadavg(&load, 3)
        loadAverage = Array(load.prefix(max(0, Int(available))))
        contended = loadAverage.first.map { $0 > Double(info.activeProcessorCount) } ?? false
        thermalState = switch info.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        lowPowerMode = info.isLowPowerModeEnabled
        #if os(macOS)
        hardwareModel = Self.sysctlString("hw.model")
        destination = "macOS"
        powerSource = IOPSCopyPowerSourcesInfo().flatMap { IOPSGetProvidingPowerSourceType($0.takeRetainedValue())?.takeUnretainedValue() as String? } ?? "unknown"
        #elseif targetEnvironment(simulator)
        hardwareModel = info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "unknown"
        destination = "iOS Simulator"
        powerSource = "simulated"
        #else
        hardwareModel = Self.sysctlString("hw.machine")
        destination = "iOS"
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        powerSource = switch device.batteryState {
        case .unplugged: "Battery"
        case .charging, .full: "External"
        default: "unknown"
        }
        device.isBatteryMonitoringEnabled = previous
        #endif
    }

    private static func sysctlString(_ name: String) -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 1 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: length)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &length, nil, 0) }
        return result == 0 ? String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) : "unknown"
    }
}

/// Background timing comes only from actual native transitions. On the simulator the
/// parent script brings another app forward, then foregrounds the existing Thrush process.
@MainActor
private final class RenderLifecycleObserver: NSObject {
    private let view: TerminalMetalView
    private var start: (time: Double, frames: Int)?
    private var observation: RenderBenchmark.IdleObservation?
    private var whileBackgrounded: (() throws -> Void)?
    private var entryError: Error?

    init(view: TerminalMetalView) { self.view = view }

    @objc private func entered() {
        guard start == nil else { return }
        start = (CACurrentMediaTime(), view.submissionCount)
        do { try whileBackgrounded?() }
        catch { entryError = error }
    }

    @objc private func returning() {
        guard let start else { return }
        observation = .init(seconds: CACurrentMediaTime() - start.time, additionalSubmissions: view.submissionCount - start.frames)
    }

    func measure(reportURL: URL, whileBackgrounded: @escaping () -> Void) async throws -> RenderBenchmark.IdleObservation {
        let center = NotificationCenter.default
        #if os(macOS)
        self.whileBackgrounded = whileBackgrounded
        let enter = NSApplication.didHideNotification
        let leave = NSApplication.willUnhideNotification
        #else
        let enteredMarker = reportURL.appendingPathExtension("background-entered")
        self.whileBackgrounded = {
            whileBackgrounded()
            // iOS may resume a suspended process. Acknowledge the actual UIKit
            // transition after recording the counter and feeding the pending update.
            try Data().write(to: enteredMarker, options: .atomic)
        }
        defer { try? FileManager.default.removeItem(at: enteredMarker) }
        let enter = UIScene.didEnterBackgroundNotification
        let leave = UIScene.willEnterForegroundNotification
        #endif
        center.addObserver(self, selector: #selector(entered), name: enter, object: nil)
        center.addObserver(self, selector: #selector(returning), name: leave, object: nil)
        defer { center.removeObserver(self) }
        #if os(macOS)
        NSApp.hide(nil)
        try await Task.sleep(for: .seconds(1.2))
        NSApp.unhide(nil)
        #else
        let marker = reportURL.appendingPathExtension("background-ready")
        try Data().write(to: marker, options: .atomic)
        defer { try? FileManager.default.removeItem(at: marker) }
        #endif
        let deadline = CACurrentMediaTime() + 70
        while observation == nil && entryError == nil {
            guard CACurrentMediaTime() < deadline else { throw RenderBenchmark.Failure("Actual background/foreground transition did not complete.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let entryError { throw entryError }
        guard let observation else { throw RenderBenchmark.Failure("Missing background observation.") }
        guard observation.seconds >= 1 else {
            throw RenderBenchmark.Failure(String(format: "Measured only %.3f s between background and foreground.", observation.seconds))
        }
        return observation
    }
}
