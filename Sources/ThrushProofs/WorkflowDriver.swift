import Foundation
import QuartzCore
import Thrush
import ThrushFixtures

/// This development-only driver observes the tab's session and drives its native
/// responder. The terminal protocol stays on the existing socket. A separate loopback HTTP
/// listener holds each reference boundary until the view, Metal, and capture runner have caught up.
@MainActor
final class WorkflowDriver {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private enum Phase: String, Decodable {
        case attaching, layout, playing, focus, input, resize, detach, resume, reclaim, newShell, checkpoint, close, completed, failed
    }
    private struct State: Decodable {
        let phase: Phase
        let eventIndex: Int
        let name: String
        let outputBytes: Int
        let attachments: Int
        let error: String?
        let capture: Bool?
        let ended: Bool?
        let archivedRows: [String]?
    }
    private struct Entry: Codable {
        let name: String, eventIndex: Int
        let columns: Int, rows: Int, receivedBytes: Int, attachments: Int
        let generation: UInt64, acceptedGeneration: UInt64, renderedGeneration: UInt64
        let synchronized: Bool, hasPresentationTime: Bool
        let copiedText: String?
        let sameNativeCanvas, sessionEnded: Bool?
        let archivedRows: [String]?
    }
    private struct Report: Encodable {
        let workflow: String, sourceSHA256: String
        let completed: Bool
        let checkpoints: [Entry]
    }

    private struct SubmittedFrame {
        let submittedAt: Double
        let generation: UInt64
        let drawableSize: CGSize
        let drawableGrid: CGRect
        let layout: WorkflowCapture.Layout
    }

    typealias NewSession = @MainActor (Int, Int, @MainActor () throws -> Void) async throws -> TerminalSession

    private let control: URL, output: URL
    private let view: TerminalMetalView
    private weak var originalSuperview: AnyObject?
    private weak var originalWindow: AnyObject?
    private var session: TerminalSession
    private let trace: WorkflowFrameTrace?
    private let setActive: (Bool) -> Void
    private let newSession: NewSession
    private var previousReceived = 0
    private var previousAttachments = 0
    private let http = URLSession(configuration: .ephemeral)
    private var lastFrame: SubmittedFrame?
    private var inFlight: [Double: SubmittedFrame] = [:]
    private var submittedGeneration: UInt64?
    private var lastTimedSubmission = -Double.infinity
    private var firstSubmission = -Double.infinity
    private var entries: [Entry] = []
    private var lastCheckpoint: Recording.Event?

    private init(control: URL, output: URL, view: TerminalMetalView, session: TerminalSession,
                 trace: WorkflowFrameTrace?, setActive: @escaping (Bool) -> Void, newSession: @escaping NewSession) {
        self.control = control
        self.output = output
        self.view = view
        self.session = session
        self.trace = trace
        self.setActive = setActive
        self.newSession = newSession
    }

    static func startIfRequested(view: TerminalMetalView, session: TerminalSession, trace: WorkflowFrameTrace?,
                                 setActive: @escaping (Bool) -> Void, newSession: @escaping NewSession) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--workflow-driver"), i + 1 < args.count,
              let j = args.firstIndex(of: "--workflow-output"), j + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[j + 1], isDirectory: true)
        Task {
            var currentDriver: WorkflowDriver?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let url = URL(string: args[i + 1]), url.scheme == "http",
                      ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "") else {
                    throw Failure("The fixture control listener must use a loopback HTTP address.")
                }
                let driver = WorkflowDriver(control: url, output: folder, view: view, session: session,
                                            trace: trace, setActive: setActive, newSession: newSession)
                currentDriver = driver
                try await driver.run()
            } catch {
                await currentDriver?.finishTrace("failure")
                let detail = String(describing: error) + "\n"
                FileHandle.standardError.write(Data(detail.utf8))
                try? detail.write(to: folder.appending(path: "workflow-error.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    /// The footer totals every shell the workflow opened.
    private func finishTrace(_ result: String) async {
        guard let trace else { return }
        await trace.finish(result, attachment: previousAttachments + session.actor.socketAttempts,
                           received: previousReceived + session.actor.receivedBytes)
    }

    private func request(_ path: String, index: Int? = nil, post: Data? = nil) async throws -> (Int, Data) {
        var url = control.appending(path: path)
        if let index { url.append(queryItems: [.init(name: "eventIndex", value: String(index))]) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if let post {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = post
        }
        let (data, response) = try await http.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw Failure("Missing HTTP response for " + path) }
        return (response.statusCode, data)
    }

    private func get(_ path: String, index: Int? = nil) async throws -> Data {
        let (status, data) = try await request(path, index: index)
        guard status == 200 else { throw httpFailure(path, status, data) }
        return data
    }

    private func httpFailure(_ path: String, _ status: Int, _ body: Data) -> Failure {
        Failure("\(path) returned HTTP \(status): " + String(decoding: body.prefix(400), as: UTF8.self))
    }

    private func run() async throws {
        // Keep the proofs app scheduled while a capture utility reads an obscured window.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "Capture native terminal checkpoints")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let trace = output.appending(path: "workflow-events.log")
        try Data().write(to: trace, options: .withoutOverwriting)
        let log = try FileHandle(forWritingTo: trace)
        defer { try? log.close() }
        let originalSubmitHook = view.onFrameSubmitted
        view.onFrameSubmitted = { [weak self] time, size, grid in
            originalSubmitHook?(time, size, grid)
            guard let self, size != nil, let snapshot = view.snapshot,
                  let layout = WorkflowCapture.Layout(view: view, drawableGrid: grid) else { return }
            submittedGeneration = snapshot.generation
            inFlight[time] = SubmittedFrame(submittedAt: time, generation: snapshot.generation,
                                            drawableSize: view.drawableSize, drawableGrid: grid, layout: layout)
        }
        let originalCompletionHook = view.onFrameCompleted
        view.onFrameCompleted = { [weak self] measurement in
            originalCompletionHook?(measurement)
            let time = measurement.submittedAt
            guard let self, let frame = inFlight.removeValue(forKey: time), measurement.gpuCompleted,
                  time >= firstSubmission, time >= (lastFrame?.submittedAt ?? -Double.infinity) else { return }
            lastFrame = frame
        }
        let originalFrameHook = view.onFrame
        view.onFrame = { [weak self] frame in
            originalFrameHook?(frame)
            guard let self, frame.presentedTime != nil else { return }
            lastTimedSubmission = max(lastTimedSubmission, frame.submittedAt)
        }
        defer {
            view.onFrame = originalFrameHook
            view.onFrameCompleted = originalCompletionHook
            view.onFrameSubmitted = originalSubmitHook
            http.invalidateAndCancel()
        }

        let fixture = try Recording.decode(await get("fixture"))
        var resizeCount = 0
        var checkKeyboardAfterShellAction = false
        var previous: (Phase, Int)?
        // The controller can wait 120 seconds for a real program to start, so outlast it.
        let patience = Duration.seconds(150)
        var deadline = ContinuousClock.now.advanced(by: patience)
        while true {
            try Task.checkCancellation()
            let state = try JSONDecoder().decode(State.self, from: await get("state"))
            let current = (state.phase, state.eventIndex)
            if previous?.0 == current.0, previous?.1 == current.1 {
                guard ContinuousClock.now < deadline else {
                    throw Failure("Timed out at \(state.phase.rawValue) \(state.eventIndex) \(state.name).")
                }
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            previous = current
            if state.phase != .playing {
                try log.write(contentsOf: Data("\(state.phase.rawValue) \(state.eventIndex) \(state.name)\n".utf8))
            }
            deadline = .now.advanced(by: patience)
            switch state.phase {
            case .attaching, .playing:
                break
            case .layout:
                try await NativeWorkflowActions.resize(.init(columns: fixture.columns, rows: fixture.rows), view: view)
                try await confirmLayout(eventIndex: -1)
                originalSuperview = view.superview
                originalWindow = view.window
            case .reclaim:
                let until = ContinuousClock.now.advanced(by: .seconds(10))
                while !view.tapDisplacedGrid() {
                    guard ContinuousClock.now < until else { throw Failure("The terminal did not accept a reclaim tap") }
                    try await Task.sleep(for: .milliseconds(25))
                }
            case .newShell:
                let until = ContinuousClock.now.advanced(by: .seconds(10))
                while !session.hasEnded {
                    guard ContinuousClock.now < until else { throw Failure("The previous session did not end") }
                    try await Task.sleep(for: .milliseconds(10))
                }
                firstSubmission = CACurrentMediaTime()
                previousReceived += await session.actor.receivedBytes
                previousAttachments += await session.actor.socketAttempts
                let action = try await newShellToolbarAction()
                session = try await newSession(previousAttachments, previousReceived, action)
                checkKeyboardAfterShellAction = true
            case .failed:
                throw Failure(state.error ?? "The controller rejected the workflow.")
            case .close:
                try await session.close()
            case .completed:
                let names = fixture.events.filter { $0.checkpoint != nil }.map(\.name)
                guard entries.map(\.name) == names else { throw Failure("The controller completed with missing checkpoints.") }
                let report = Report(workflow: fixture.name, sourceSHA256: fixture.sha256, completed: true, checkpoints: entries)
                await finishTrace("success")
                try save(report, as: "workflow-report.json")
                return
            case .focus, .input, .resize, .detach, .resume, .checkpoint:
                guard fixture.events.indices.contains(state.eventIndex) else { throw Failure("Invalid fixture event index.") }
                let event = fixture.events[state.eventIndex]
                guard event.name == state.name else { throw Failure("The view and controller use different recordings.") }
                switch state.phase {
                case .focus:
                    try await NativeWorkflowActions.focusForTyping(view)
                    checkKeyboardAfterShellAction = false
                    try await confirmLayout(eventIndex: state.eventIndex)
                case .input:
                    guard let action = event.semanticInput else { throw Failure("Missing native action for \(event.name).") }
                    try NativeWorkflowActions.input(action, view: view)
                case .resize:
                    guard let grid = event.resize else { throw Failure("Missing resize for \(event.name).") }
                    resizeCount += 1
                    let landscape = fixture.name == "vim-resume" && resizeCount == 2
                    try await NativeWorkflowActions.resize(.init(columns: grid.columns, rows: grid.rows),
                                                         view: view, landscape: landscape)
                    try await confirmLayout(eventIndex: state.eventIndex)
                case .detach:
                    setActive(false)
                case .resume:
                    // Ignore an old command buffer completing after the new attachment starts.
                    firstSubmission = CACurrentMediaTime()
                    setActive(true)
                case .checkpoint:
                    let projected = try Recording.decode(await get("checkpoint", index: state.eventIndex))
                    guard projected.events.count == 1, let expected = projected.events.first, expected.name == event.name else {
                        throw Failure("The reference omitted \(event.name).")
                    }
                    let entry = try await inspect(expected, state: state, lifecycle: fixture.name == "live-lifecycle")
                    if checkKeyboardAfterShellAction {
                        try await NativeWorkflowActions.verifyKeyboardDown(view)
                        checkKeyboardAfterShellAction = false
                    }
                    entries.append(entry)
                    lastCheckpoint = expected
                    let captures = state.capture ?? shouldCapture(event.name)
                    if captures { try await capture(entry, ended: state.ended == true) }
                    if let archived = state.archivedRows { try await readPreviousShell(archived, capturing: captures ? entry : nil) }
                    if state.ended == true { try await pauseForLifecycleRecording() }
                    let (status, body) = try await request("ack", post: JSONEncoder().encode(entry))
                    guard status == 204 else { throw httpFailure("ack", status, body) }
                    try log.write(contentsOf: Data("ack \(state.eventIndex) \(entry.receivedBytes) bytes\n".utf8))
                default: break
                }
            }
        }
    }

    private func confirmLayout(eventIndex: Int) async throws {
        var lastSize: Terminal.Size?
        var since = ContinuousClock.now
        let deadline = since.advanced(by: .seconds(12))
        while ContinuousClock.now < deadline {
            if let size = view.gridSize {
                if lastSize != size { lastSize = size; since = .now }
                if since.duration(to: .now) >= .milliseconds(350) {
                    let geometry = ["eventIndex": eventIndex, "columns": size.columns, "rows": size.rows]
                    let (status, data) = try await request("layout", post: JSONEncoder().encode(geometry))
                    if status == 204 { return }
                    if status != 409 { throw httpFailure("layout", status, data) }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure("The view and its WebSocket did not settle on the same grid at event \(eventIndex).")
    }

    private func inspect(_ expected: Recording.Event, state: State, lifecycle: Bool) async throws -> Entry {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var redrawAfter = ContinuousClock.now.advanced(by: .seconds(1))
        var detail = "Waiting for the recorded output"
        var copied: String?
        var copiedAt: Double?
        while ContinuousClock.now < deadline {
            let received = await session.actor.receivedBytes + previousReceived
            if received == state.outputBytes {
                let snapshot = await session.actor.snapshot()
                let accepted = view.snapshot
                // MTKView's initial on-demand draw can run before a drawable becomes available.
                // Ask the native view to retry that dirty frame while the fixture holds its output.
                if let accepted, submittedGeneration != accepted.generation, ContinuousClock.now >= redrawAfter {
                    redrawAfter = .now.advanced(by: .seconds(2))
                    view.draw()
                }
                do {
                    if let copy = expected.copy, copied == nil, accepted?.generation == snapshot.generation,
                       lastFrame?.generation == snapshot.generation {
                        copiedAt = CACurrentMediaTime()
                        copied = try NativeWorkflowActions.copy(copy, view: view)
                    }
                    guard let accepted, let frame = lastFrame else { throw Failure("The view has no rendered checkpoint yet.") }
                    if let copiedAt, frame.submittedAt < copiedAt { throw Failure("Waiting for the native selection highlight.") }
                    if expected.lifecycle?.resumed == true {
                        // A continuing session keeps its previous screen until the replay arrives.
                        guard let previous = lastCheckpoint, snapshot.generation == accepted.generation,
                              accepted.generation == frame.generation else {
                            throw Failure("The view lost its pre-detach frame while waiting for replay.")
                        }
                        try previous.verify(snapshot)
                        try previous.verify(accepted)
                    } else {
                        try WorkflowCheckpoint.verify(expected, snapshot: snapshot, nativePalette: view.resolvedTheme.palette,
                                                      accepted: accepted, renderedGeneration: frame.generation, copiedText: copied)
                    }
                    if lifecycle {
                        guard let originalSuperview, let originalWindow,
                              view.superview === originalSuperview, view.window === originalWindow else {
                            throw Failure("The native terminal moved to another canvas or window")
                        }
                        guard session.hasEnded == (state.ended == true) else {
                            throw Failure("The native session has an unexpected end state")
                        }
                    }
                    if let markers = state.archivedRows {
                        var remaining = markers[...]
                        for row in snapshot.history where row.text == remaining.first { remaining = remaining.dropFirst() }
                        guard remaining.isEmpty else { throw Failure("The native scrollback lost earlier shell rows") }
                    }
                    return Entry(name: expected.name, eventIndex: state.eventIndex, columns: snapshot.size.columns,
                                 rows: snapshot.size.rows, receivedBytes: received,
                                 attachments: state.attachments, generation: snapshot.generation,
                                 acceptedGeneration: accepted.generation, renderedGeneration: frame.generation,
                                 synchronized: snapshot.synchronizedOutputID != nil, hasPresentationTime: lastTimedSubmission == frame.submittedAt,
                                 copiedText: copied, sameNativeCanvas: lifecycle ? true : nil,
                                 sessionEnded: lifecycle ? session.hasEnded : nil, archivedRows: state.archivedRows)
                } catch {
                    detail = "\(error) (session cursor row \(snapshot.cursorRow), displayed \(accepted?.cursorRow ?? -1), history offset \(view.historyOffset))"
                }
            } else {
                detail = "controller sent \(state.outputBytes), session received \(received)"
            }
            try await Task.sleep(for: .milliseconds(8))
        }
        let submitted = submittedGeneration.map(String.init) ?? "none"
        let completed = lastFrame.map { String($0.generation) } ?? "none"
        throw Failure("\(expected.name): \(detail) (submitted \(submitted), GPU-completed \(completed))")
    }

    private func shouldCapture(_ name: String) -> Bool {
        switch name {
        case "Pasted build command", "Copy soft-wrapped compiler path", "Edited scratch file",
             "Vim before detach", "Vim serialized replay", "Codex ready", "First three songbirds streamed",
             "Received Codex answer", "Earlier transcript page", "Returned to shell": true
        default: false
        }
    }

    /// Read the previous shell through the mounted viewport, show its last rows directly above
    /// the fresh prompt, then return to that prompt.
    private func readPreviousShell(_ markers: [String], capturing entry: Entry?) async throws {
        guard let live = view.snapshot, view.historyOffset == 0 else { throw Failure("The replacement did not open at the live prompt") }
        defer { view.setHistoryOffset(0) }
        try await pauseForLifecycleRecording()
        for marker in markers {
            if view.snapshot?.rows.contains(where: { $0.text == marker }) == true { continue }
            guard let index = live.history.firstIndex(where: { $0.text == marker }) else {
                throw Failure("The previous shell is missing \(marker)")
            }
            view.setHistoryOffset(live.history.count - index)
            guard view.snapshot?.rows.first?.text == marker else { throw Failure("Scrolling did not display \(marker)") }
        }
        let shown = min(live.history.count, live.size.rows - live.cursorRow - 1)
        view.setHistoryOffset(shown)
        let seam = (live.history.count - shown..<live.history.count - shown + live.size.rows).map { live.row(atAbsoluteIndex: $0).text }
        guard view.snapshot?.rows.map(\.text) == seam, seam.contains(markers.last ?? "") else {
            throw Failure("The previous shell does not sit directly above the replacement prompt")
        }
        let scrolledAt = CACurrentMediaTime()
        try await pauseForLifecycleRecording()
        if let entry { try await capture(entry, ended: false, scrolledAt: scrolledAt) }
        view.setHistoryOffset(0)
        guard view.snapshot?.rows.map(\.text) == live.rows.map(\.text) else { throw Failure("Returning to live lost the replacement prompt") }
    }

    private func pauseForLifecycleRecording() async throws {
        #if os(iOS)
        if CommandLine.arguments.contains("--trace-lifecycle-frames") { try await Task.sleep(for: .seconds(1.5)) }
        #endif
    }

    private func newShellToolbarAction() async throws -> @MainActor () throws -> Void {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let action = NativeWorkflowActions.newShellAction(in: view) { return action }
            try await Task.sleep(for: .milliseconds(25))
        }
        var message = "The app toolbar has no enabled New Shell action."
        #if os(iOS)
        message += " " + NativeWorkflowActions.toolbarDescription(in: view)
        #endif
        throw Failure(message)
    }

    /// `scrolledAt` captures the checkpoint again from history, once a frame drawn after that scroll completes.
    private func capture(_ entry: Entry, ended: Bool, scrolledAt: Double? = nil) async throws {
        if ended {
            guard session.hasEnded else { throw Failure("The session has not published its end") }
            _ = try await newShellToolbarAction()
            try await NativeWorkflowActions.verifyKeyboardDown(view)
            guard view.cursorSpinnerFrameInWindow == nil else { throw Failure("The ended terminal still shows a connecting cursor") }
        }
        var base = String(format: "capture-%03d", entry.eventIndex), name = entry.name
        if let scrolledAt {
            base += "-history"
            name += ", scrolled to the previous shell"
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while (lastFrame?.submittedAt ?? 0) <= scrolledAt {
                guard ContinuousClock.now < deadline else { throw Failure("No frame showed the previous shell") }
                view.draw()
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard let accepted = view.snapshot, accepted.generation == entry.acceptedGeneration,
              let frame = lastFrame, frame.generation == entry.renderedGeneration else {
            throw Failure("Missing the submitted grid for " + name)
        }
        let layout = ended ? try await settledFinalLayout(generation: entry.renderedGeneration) : frame.layout
        let marker = WorkflowCapture(name: name, eventIndex: entry.eventIndex, view: view,
                                     snapshot: accepted, layout: layout, copied: entry.copiedText, ended: ended)
        try save(marker, as: base + ".json")
        let ack = output.appending(path: base + ".done")
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !FileManager.default.fileExists(atPath: ack.path) {
            guard ContinuousClock.now < deadline else { throw Failure("No native screenshot for " + name) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// UIKit can resize the Metal drawable as it dismisses the keyboard and displays the toolbar,
    /// and until the keyboard stops the view holds its grid in a drawable that differs from its bounds.
    private func settledFinalLayout(generation: UInt64) async throws -> WorkflowCapture.Layout {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var size = view.drawableSize
        var since = ContinuousClock.now
        while ContinuousClock.now < deadline {
            if size != view.drawableSize { size = view.drawableSize; since = .now }
            if let frame = lastFrame, frame.generation == generation, frame.drawableSize == size, size == boundsInPixels,
               since.duration(to: .now) >= .milliseconds(300),
               let layout = WorkflowCapture.Layout(view: view, drawableGrid: frame.drawableGrid) {
                return layout
            }
            view.draw()
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure("Final framebuffer did not settle at \(view.drawableSize) for a \(boundsInPixels) view, last completed \(String(describing: lastFrame?.drawableSize))")
    }

    private var boundsInPixels: CGSize {
        #if os(macOS)
        let scale = view.window?.backingScaleFactor ?? 1
        #else
        let scale = view.traitCollection.displayScale
        #endif
        return CGSize(width: (view.bounds.width * scale).rounded(), height: (view.bounds.height * scale).rounded())
    }

    private func save(_ value: some Encodable, as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: output.appending(path: name), options: .atomic)
    }
}
