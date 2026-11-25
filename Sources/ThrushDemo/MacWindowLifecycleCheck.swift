#if os(macOS)
import AppKit
import QuartzCore
import Thrush
import ThrushConnection
import ThrushUI

/// Opt-in proof running inside the normal packaged pane. No visibility or input overrides.
@MainActor
final class MacWindowLifecycleCheck {
    private enum Phase: String, CaseIterable { case covered, minimized, hidden }
    private struct Marker { let pid, tick: Int }
    private struct Interval: Encodable {
        let phase: String
        let durationSeconds: Double
        let shellPID, firstTick, finalTick, hiddenSubmissions: Int
        let hiddenGeneration, revealedGeneration: UInt64
        let frontmostBundle: String?
    }
    private struct Report: Encodable {
        let socketAttempts, readyEvents: Int
        let intervals: [Interval]
    }

    private let session: DemoSession
    private let window: NSWindow
    private let coverURL: URL
    private let coverID = "app.thrush.lifecycle-cover"
    private var cover: NSRunningApplication?
    private var phase: Phase?
    private var hiddenSubmissions = 0
    private var readyEvents = 0
    private var submitted = 0
    private var completed = 0
    private var inFlight: [Double: UInt64] = [:]
    private var lastCompleted: UInt64?

    private init(_ session: DemoSession, _ window: NSWindow, _ coverURL: URL) {
        self.session = session
        self.window = window
        self.coverURL = coverURL
    }

    static func startIfRequested(session: DemoSession, window: NSWindow) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--window-lifecycle-check"), index + 2 < arguments.count else { return }
        let destination = URL(fileURLWithPath: arguments[index + 1])
        let check = Self(session, window, URL(fileURLWithPath: arguments[index + 2]))
        check.observe()
        Task {
            do {
                let report = try await check.run()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: destination, options: .atomic)
                NSApp.terminate(nil)
            } catch {
                check.cover?.terminate()
                FileHandle.standardError.write(Data("Window lifecycle check failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
    }

    private func observe() {
        session.onReady = { [weak self] _ in self?.readyEvents += 1 }
        session.view.onFrameSubmitted = { [weak self] time, _, _ in
            guard let self else { return }
            submitted += 1
            if let generation = session.view.snapshot?.generation { inFlight[time] = generation }
            if let phase, isObscured(phase) { hiddenSubmissions += 1 }
        }
        session.view.onFrameCompleted = { [weak self] frame in
            guard let self, let generation = inFlight.removeValue(forKey: frame.submittedAt), frame.gpuCompleted else { return }
            completed += 1
            lastCompleted = max(lastCompleted ?? 0, generation)
        }
    }

    private var frontmost: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    private var visible: Bool {
        window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized && !NSApp.isHidden
    }

    private func isObscured(_ phase: Phase) -> Bool {
        switch phase {
        case .covered: !window.occlusionState.contains(.visible) && frontmost == coverID && !window.isMiniaturized && !NSApp.isHidden
        case .minimized: window.isMiniaturized
        case .hidden: NSApp.isHidden
        }
    }

    private func wait(_ description: String, timeout: Double = 12, until predicate: () async -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while !(await predicate()) {
            guard CACurrentMediaTime() < deadline else {
                throw RenderBenchmark.Failure("\(description); frontmost=\(frontmost ?? "none"), windowVisible=\(visible), ready=\(readyEvents), submitted=\(submitted), completed=\(completed), nativeGeneration=\(String(describing: session.view.snapshot?.generation)), completedGeneration=\(String(describing: lastCompleted)).")
            }
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    private func run() async throws -> Report {
        guard let connection = session.connection else { throw RenderBenchmark.Failure("Missing shell connection.") }
        try await wait("The uncovered terminal must have a usable shell", timeout: 25) { readyEvents == 1 && visible }
        // The terminal itself must be a tty, and the shell supplies its own PID and monotonic tick.
        let command = #"if test -t 0; then i=0; while test "$i" -lt 145; do printf 'thrush-cover %s %s\n' "$$" "$i"; i=$((i+1)); sleep 1; done; fi"#
        try NativeWorkflowActions.input(.text(command + "\r"), view: session.view)
        try await wait("The real shell must write its PID into the emulator") { self.marker(in: await connection.snapshot()) != nil }
        try await wait("The uncovered terminal must render its first shell marker", timeout: 25) {
            guard let snapshot = self.session.view.snapshot, self.marker(in: snapshot) != nil,
                  let completed = self.lastCompleted else { return false }
            return self.visible && completed >= snapshot.generation
        }
        var intervals: [Interval] = []
        for step in Phase.allCases { intervals.append(try await measure(step, connection: connection)) }
        let attempts = await connection.socketAttempts
        guard attempts == 1, readyEvents == 1 else {
            throw RenderBenchmark.Failure("Expected one socket and one ready, observed \(attempts) and \(readyEvents).")
        }
        try await connection.closeShell()
        return Report(socketAttempts: attempts, readyEvents: readyEvents, intervals: intervals)
    }

    private func measure(_ step: Phase, connection: TerminalConnection) async throws -> Interval {
        phase = step
        hiddenSubmissions = 0
        switch step {
        case .covered:
            let rect = window.frame
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.arguments = [rect.minX, rect.minY, rect.width, rect.height].map { String(Double($0)) }
            cover = try await NSWorkspace.shared.openApplication(at: coverURL, configuration: configuration)
        case .minimized:
            window.performMiniaturize(nil)
        case .hidden:
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "h",
                                               charactersIgnoringModifiers: "h", isARepeat: false, keyCode: 4),
                  NSApp.mainMenu?.performKeyEquivalent(with: event) == true else {
                throw RenderBenchmark.Failure("The native Hide Thrush keyboard equivalent was unavailable.")
            }
        }
        try await wait("WindowServer did not confirm \(step.rawValue)") { isObscured(step) }
        let initialModel = await connection.snapshot()
        guard let first = marker(in: initialModel) else { throw RenderBenchmark.Failure("Missing shell PID marker.") }
        let other = frontmost
        let start = CACurrentMediaTime()
        repeat {
            guard isObscured(step), hiddenSubmissions == 0 else {
                throw RenderBenchmark.Failure("\(step.rawValue) changed during observation or submitted \(hiddenSubmissions) frames.")
            }
            try await Task.sleep(for: .milliseconds(100))
        } while CACurrentMediaTime() - start < 32
        let elapsed = CACurrentMediaTime() - start
        let hiddenModel = await connection.snapshot()
        let generation = hiddenModel.generation
        guard let final = marker(in: hiddenModel), generation > initialModel.generation, final.pid == first.pid,
              final.tick >= first.tick + 20,
              hiddenSubmissions == 0 else { throw RenderBenchmark.Failure("Shell or terminal output stalled while \(step.rawValue).") }
        phase = nil
        switch step {
        case .covered: cover?.terminate()
        case .minimized: window.deminiaturize(nil)
        case .hidden: NSApp.unhide(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await wait("A completed frame must include the output parsed during \(step.rawValue)") {
            visible && (lastCompleted ?? 0) >= generation
        }
        guard let revealed = marker(in: session.view.snapshot), revealed.pid == final.pid, revealed.tick >= final.tick else {
            throw RenderBenchmark.Failure("The native display did not present the parsed shell output after reveal.")
        }
        return Interval(phase: step.rawValue, durationSeconds: elapsed, shellPID: final.pid, firstTick: first.tick,
                        finalTick: final.tick, hiddenSubmissions: hiddenSubmissions, hiddenGeneration: generation,
                        revealedGeneration: lastCompleted!, frontmostBundle: other)
    }

    private func marker(in snapshot: Terminal.Snapshot?) -> Marker? {
        guard let snapshot else { return nil }
        for row in snapshot.rows.reversed() {
            let fields = row.text.split(separator: " ")
            if fields.count == 3, fields[0] == "thrush-cover", let pid = Int(fields[1]), let tick = Int(fields[2]) {
                return Marker(pid: pid, tick: tick)
            }
        }
        return nil
    }
}
#endif
