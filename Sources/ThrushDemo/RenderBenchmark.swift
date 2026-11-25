import CryptoKit
import Darwin
import Foundation
import QuartzCore
import Thrush
import ThrushUI
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
        let generation: UInt64
        let receivedAt: Double
        let submittedAt: Double
        let presentedTime: Double?
        let cpuPreparationSeconds: Double
        let shaderCompileSeconds: Double?
        let firstFrameSeconds: Double?
        let gpuSeconds: Double?
        let glyphUploads: Int
        let rowsPrepared: Int

        var receiptToPresentation: Double? { presentedTime.map { $0 - receivedAt } }
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

    private struct ThemeSwitch: Encodable {
        let theme: String
        let generation: UInt64
        let submittedAt: Double
        let presentedTime: Double?
        let rowsPrepared: Int
        let glyphUploads: Int
    }

    private struct Report: Encodable {
        let schemaVersion = 2
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
        let inactiveRenderer: IdleObservation
        let background: IdleObservation?
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
            let cpu = matching.map { $0.cpuPreparationSeconds * 1_000 }
            let gpu = matching.compactMap(\.gpuSeconds).map { $0 * 1_000 }
            let latency = matching.compactMap(\.receiptToPresentation)
            return Workload(operation: operation, frames: matching.count,
                            unpresented: matching.count - latency.count,
                            cpuP50Milliseconds: quantile(cpu, 0.5),
                            cpuP95Milliseconds: quantile(cpu, 0.95),
                            gpuP95Milliseconds: quantile(gpu, 0.95),
                            receiptToPresentationP95Milliseconds: quantile(latency.map { $0 * 1_000 }, 0.95),
                            glyphUploads: matching.map(\.glyphUploads).reduce(0, +),
                            maximumRowsPrepared: matching.map(\.rowsPrepared).max() ?? 0,
                            overTwoDisplayIntervals: latency.filter { $0 > 2 * interval }.count)
        }
    }

    static func run(on view: TerminalView, size: Terminal.Size, reportURL: URL) async throws {
        #if DEBUG
        throw Failure("Build the packaged demo in Release to measure rendering.")
        #else
        guard size.columns >= 24, size.rows >= 2 else { throw Failure("Render benchmark needs at least 24 × 2.") }
        let collector = FrameCollector(view: view, size: size)
        let previousCallback = view.onFrame
        view.onFrame = { frame in collector.receive(frame) }
        defer { view.onFrame = previousCallback }
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
        let selection = TerminalView.Selection(anchorRow: 0, anchorColumn: 1, headRow: 0, headColumn: 4)
        try await collector.observeMutation { view.selection = selection }
        var alternate = TerminalTheme.slateDark
        alternate.cursor = .init(red: 0x82, green: 0xCB, blue: 0xC5)
        let firstTheme: TerminalTheme = view.resolvedTheme == .slateDark ? .slateLight : .slateDark
        let secondTheme: TerminalTheme = firstTheme == .slateDark ? .slateLight : .slateDark
        let themes = [firstTheme, secondTheme, alternate]
        var switches: [ThemeSwitch] = []
        for theme in themes {
            let frame = try await collector.observeMutation { view.theme = theme }
            guard view.selection == selection, view.resolvedTheme == theme, view.gridSize == size else {
                throw Failure("Changing appearance displaced the selection or resized the grid.")
            }
            let name = theme == .slateDark ? "Slate Dark" : theme == .slateLight ? "Slate Light" : "Custom"
            switches.append(.init(theme: name, generation: frame.generation, submittedAt: frame.submittedAt,
                                  presentedTime: frame.presentedTime, rowsPrepared: frame.rowsPrepared,
                                  glyphUploads: frame.glyphUploads))
        }
        try await collector.observeMutation {
            view.theme = originalTheme
            view.selection = nil
        }
        let foregroundIdle = try await observeIdle(view)
        view.setRenderingActive(false)
        // Exercise the same suspension switch the host calls on backgrounding. Keep an
        // update pending, so a renderer that merely suppresses its timer fails this check.
        let inactive: IdleObservation
        let before = view.submissionCount
        let start = CACurrentMediaTime()
        _ = collector.terminal.receive("\u{1b}[1;3H".utf8)
        view.display(collector.terminal)
        try await Task.sleep(for: .seconds(1))
        inactive = IdleObservation(seconds: CACurrentMediaTime() - start,
                                   additionalSubmissions: view.submissionCount - before)

        let workloadSHA256 = collector.hash.finalize().hexString
        view.setRenderingActive(true)
        let background: IdleObservation?
        if CommandLine.arguments.contains("--lifecycle-check") {
            // A return from the inactive probe may submit its pending generation. Wait for
            // it before observing the operating system's own transition.
            try await collector.apply("\u{1b}[1;6H", as: "restore")
            let observer = RenderLifecycleObserver(view: view)
            background = try await observer.measure(reportURL: reportURL) {
                _ = collector.terminal.receive("\u{1b}[1;3H".utf8)
                view.display(collector.terminal)
            }
        } else {
            background = nil
        }

        let samples = collector.samples.filter { $0.operation != "restore" }
        let workloads = summarize(samples, interval: interval)
        let report = Report(recordedAt: Date(), workloadSHA256: workloadSHA256,
                            environment: environment, columns: size.columns, rows: size.rows,
                            displayIntervalSeconds: interval, samples: samples, workloads: workloads,
                            themeSwitches: switches, foregroundIdle: foregroundIdle, inactiveRenderer: inactive, background: background)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (encoder.encode(report) + Data([0x0A])).write(to: reportURL, options: .atomic)
        print("ThrushBench render   \(size.columns) × \(size.rows)   \(environment.hardwareModel)   \(environment.commit.prefix(12))")
        print("Load \(environment.loadAverage)   \(environment.coreCount) cores   contended \(environment.contended)   thermal \(environment.thermalState)")
        print("Operation   frames   CPU p95 ms   GPU p95 ms   receipt → presentation p95 ms   uploads   max rows")
        func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "unavailable" }
        for work in workloads {
            print("\(work.operation)   \(work.frames)   \(milliseconds(work.cpuP95Milliseconds))   \(milliseconds(work.gpuP95Milliseconds))   \(milliseconds(work.receiptToPresentationP95Milliseconds))   \(work.glyphUploads)   \(work.maximumRowsPrepared)")
        }
        if let compile = samples.first?.shaderCompileSeconds, let first = samples.first?.firstFrameSeconds {
            print(String(format: "Runtime shader compile %.3f ms   first content submission %.3f ms", compile * 1_000, first * 1_000))
        }
        print("Additional submissions   settled \(foregroundIdle.additionalSubmissions)   inactive \(inactive.additionalSubmissions)")
        if let background { print("Additional submissions   background \(background.additionalSubmissions)") }
        print("Report \(reportURL.path)")
        guard foregroundIdle.additionalSubmissions == 0, inactive.additionalSubmissions == 0,
              (background?.additionalSubmissions ?? 0) == 0,
              switches.allSatisfy({ $0.rowsPrepared == 0 && $0.glyphUploads == 0 }),
              samples[0].glyphUploads > 0, samples[0].rowsPrepared == size.rows,
              samples.dropFirst().allSatisfy({ $0.glyphUploads == 0 }),
              samples.filter({ ["oneRow", "cursor"].contains($0.operation) }).allSatisfy({ $0.rowsPrepared <= 1 }),
              samples.filter({ $0.operation == "full" }).allSatisfy({ $0.rowsPrepared == size.rows })
        else { throw Failure("Draw cache, atlas warmup or settled frame checkpoint failed. See \(reportURL.path).") }
        #endif
    }

    private static func observeIdle(_ view: TerminalView) async throws -> IdleObservation {
        let before = view.submissionCount
        let start = CACurrentMediaTime()
        try await Task.sleep(for: .seconds(1))
        return IdleObservation(seconds: CACurrentMediaTime() - start, additionalSubmissions: view.submissionCount - before)
    }

    @MainActor
    private final class FrameCollector {
        let view: TerminalView
        var terminal: Terminal
        var hash = SHA256()
        var samples: [Sample] = []
        var latest: FrameMeasurement?

        init(view: TerminalView, size: Terminal.Size) {
            self.view = view
            terminal = Terminal(size: size)
        }

        func receive(_ frame: FrameMeasurement) { latest = frame }

        @discardableResult
        func observeMutation(_ mutation: () -> Void) async throws -> FrameMeasurement {
            latest = nil
            let start = CACurrentMediaTime()
            let generation = terminal.snapshot().generation
            mutation()
            while latest?.generation != generation || (latest?.submittedAt ?? 0) < start {
                guard CACurrentMediaTime() - start < 15 else { throw Failure("No frame after a viewport or theme change.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let latest else { throw Failure("Missing frame after changing appearance.") }
            return latest
        }

        func apply(_ string: String, as operation: String) async throws {
            let bytes = Array(string.utf8)
            hash.update(data: bytes)
            latest = nil
            let receipt = CACurrentMediaTime()
            _ = terminal.receive(bytes)
            let expected = terminal.snapshot().generation
            view.display(terminal, receivedAt: receipt)
            let deadline = receipt + 15
            while latest?.generation != expected || latest?.receivedAt != receipt {
                guard CACurrentMediaTime() < deadline else { throw Failure("No frame result for \(operation), generation \(expected).") }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let frame = latest else { throw Failure("Missing frame statistics.") }
            if let presented = frame.presentedTime, presented <= 0 || presented < receipt {
                throw Failure("Invalid drawable presentation timestamp for \(operation).")
            }
            samples.append(Sample(operation: operation, generation: expected, receivedAt: receipt,
                                  submittedAt: frame.submittedAt, presentedTime: frame.presentedTime,
                                  cpuPreparationSeconds: frame.cpuPreparationSeconds,
                                  shaderCompileSeconds: frame.shaderCompileSeconds, firstFrameSeconds: frame.firstFrameSeconds,
                                  gpuSeconds: frame.gpuSeconds,
                                  glyphUploads: frame.glyphUploads, rowsPrepared: frame.rowsPrepared))
        }
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

@MainActor
private final class DisplayInterval: NSObject {
    private var periods: [Double] = []

    @objc private func tick(_ link: CADisplayLink) {
        let interval = link.targetTimestamp - link.timestamp
        if interval > 0, interval.isFinite { periods.append(interval) }
    }

    static func measure(on view: TerminalView) async throws -> Double {
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

private struct RenderEnvironment: Encodable {
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
    private let view: TerminalView
    private var start: (time: Double, frames: Int)?
    private var observation: RenderBenchmark.IdleObservation?
    private var whileBackgrounded: (() -> Void)?

    init(view: TerminalView) { self.view = view }

    @objc private func entered() {
        guard start == nil else { return }
        start = (CACurrentMediaTime(), view.submissionCount)
        whileBackgrounded?()
    }

    @objc private func returning() {
        guard let start else { return }
        observation = .init(seconds: CACurrentMediaTime() - start.time, additionalSubmissions: view.submissionCount - start.frames)
    }

    func measure(reportURL: URL, whileBackgrounded: @escaping () -> Void) async throws -> RenderBenchmark.IdleObservation {
        self.whileBackgrounded = whileBackgrounded
        let center = NotificationCenter.default
        #if os(macOS)
        let enter = NSApplication.didHideNotification
        let leave = NSApplication.willUnhideNotification
        #else
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
        while observation == nil {
            guard CACurrentMediaTime() < deadline else { throw RenderBenchmark.Failure("Actual background/foreground transition did not complete.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let observation, observation.seconds >= 1 else { throw RenderBenchmark.Failure("Background observation was shorter than one second.") }
        return observation
    }
}
