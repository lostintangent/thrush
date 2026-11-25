import Foundation
import QuartzCore
import Thrush
import ThrushReplay

/// This development-only driver observes the tab's real connection and drives its native
/// responder. The terminal protocol stays on the existing socket. A separate loopback HTTP
/// listener holds each reference boundary until the pane, Metal, and capture runner have caught up.
@MainActor
final class PaneWorkflowDriver {
    static let clientID = "thrush-native-workflow"

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
    private enum Phase: String, Decodable {
        case attaching, layout, playing, focus, input, resize, detach, resume, useHere, newShell, checkpoint, close, completed, failed
    }
    private struct State: Decodable {
        let phase: Phase
        let eventIndex: Int
        let name: String
        let outputBytes: Int
        let attachments: Int
        let error: String?
        let capture: Bool?
        let endedNotice: Bool?
    }
    private struct Entry: Codable {
        let name: String, eventIndex: Int
        let columns: Int, rows: Int, receivedBytes: Int, appliedBytes: Int, attachments: Int
        let generation: UInt64, acceptedGeneration: UInt64, renderedGeneration: UInt64
        let synchronized: Bool, hasPresentationTime: Bool
        let copiedText: String?
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

    private let control: URL, output: URL
    private let view: TerminalView
    private let shell: TerminalShell
    private var connection: TerminalConnection { shell.connection }
    private let setActive: (Bool) -> Void
    private let activateAction: (String) -> Bool
    private let http = URLSession(configuration: .ephemeral)
    private var lastFrame: SubmittedFrame?
    private var inFlight: [Double: SubmittedFrame] = [:]
    private var submittedGeneration: UInt64?
    private var lastTimedSubmission = -Double.infinity
    private var firstSubmission = -Double.infinity
    private var entries: [Entry] = []
    private var lastCheckpoint: ReplayFixture.Event?

    private init(control: URL, output: URL, view: TerminalView, shell: TerminalShell,
                 setActive: @escaping (Bool) -> Void, activateAction: @escaping (String) -> Bool) {
        self.control = control
        self.output = output
        self.view = view
        self.shell = shell
        self.setActive = setActive
        self.activateAction = activateAction
    }

    static func startIfRequested(view: TerminalView, shell: TerminalShell, setActive: @escaping (Bool) -> Void,
                                 activateAction: @escaping (String) -> Bool) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--workflow-driver"), i + 1 < args.count,
              let j = args.firstIndex(of: "--workflow-output"), j + 1 < args.count else { return }
        let folder = URL(fileURLWithPath: args[j + 1], isDirectory: true)
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let url = URL(string: args[i + 1]), url.scheme == "http",
                      ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "") else {
                    throw Failure("The fixture control listener must use a loopback HTTP address.")
                }
                let driver = PaneWorkflowDriver(control: url, output: folder, view: view,
                                                shell: shell, setActive: setActive, activateAction: activateAction)
                try await driver.run()
            } catch {
                await shell.connection.finishFrameTrace("failure")
                let detail = String(describing: error) + "\n"
                FileHandle.standardError.write(Data(detail.utf8))
                try? detail.write(to: folder.appending(path: "workflow-error.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    private func request(_ path: String, index: Int? = nil, post: Data? = nil) async throws -> (Int, Data) {
        var url = control.appending(path: path)
        var query = [URLQueryItem(name: "clientId", value: Self.clientID)]
        if let index { query.append(.init(name: "eventIndex", value: String(index))) }
        url.append(queryItems: query)
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
        // Keep the development host scheduled while a capture utility reads an obscured window.
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

        var fixture = try ReplayFixture.decode(await get("fixture"))
        var resizeCount = 0
        var checkKeyboardAfterShellAction = false
        var previous: (Phase, Int)?
        var deadline = ContinuousClock.now.advanced(by: .seconds(45))
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
            deadline = .now.advanced(by: .seconds(45))
            switch state.phase {
            case .attaching, .playing:
                break
            case .layout:
                try await NativeWorkflowActions.resize(.init(columns: fixture.columns, rows: fixture.rows), view: view)
                try await confirmLayout(eventIndex: -1)
                // The peer can select a source recorded at the settled handset geometry.
                fixture = try ReplayFixture.decode(await get("fixture"))
            case .useHere, .newShell:
                let title = state.phase == .useHere ? "Use shell in this window" : "New Shell"
                let until = ContinuousClock.now.advanced(by: .seconds(10))
                while !activateAction(title) {
                    guard ContinuousClock.now < until else { throw Failure("No enabled pane button named " + title) }
                    try await Task.sleep(for: .milliseconds(25))
                }
                checkKeyboardAfterShellAction = true
            case .failed:
                throw Failure(state.error ?? "The peer rejected the workflow.")
            case .close:
                try await shell.close()
            case .completed:
                let names = fixture.events.filter { $0.checkpoint != nil }.map(\.name)
                guard entries.map(\.name) == names else { throw Failure("The peer completed with missing checkpoints.") }
                let report = Report(workflow: fixture.name, sourceSHA256: fixture.sha256, completed: true, checkpoints: entries)
                await connection.finishFrameTrace("success")
                try save(report, as: "workflow-report.json")
                return
            case .focus, .input, .resize, .detach, .resume, .checkpoint:
                guard fixture.events.indices.contains(state.eventIndex) else { throw Failure("Invalid fixture event index.") }
                let event = fixture.events[state.eventIndex]
                guard event.name == state.name else { throw Failure("The pane and socket peer use different recordings.") }
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
                    let projected = try ReplayFixture.decode(await get("checkpoint", index: state.eventIndex))
                    guard projected.events.count == 1, let expected = projected.events.first, expected.name == event.name else {
                        throw Failure("The reference omitted \(event.name).")
                    }
                    let entry = try await inspect(expected, state: state)
                    if checkKeyboardAfterShellAction {
                        try await NativeWorkflowActions.verifyKeyboardDown(view)
                        checkKeyboardAfterShellAction = false
                    }
                    entries.append(entry)
                    lastCheckpoint = expected
                    if state.capture ?? shouldCapture(event.name) { try await capture(entry, endedNotice: state.endedNotice == true) }
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
        throw Failure("The pane and its WebSocket did not settle on the same grid at event \(eventIndex).")
    }

    private func inspect(_ expected: ReplayFixture.Event, state: State) async throws -> Entry {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var redrawAfter = ContinuousClock.now.advanced(by: .seconds(1))
        var detail = "Waiting for the recorded output"
        var copied: String?
        var copiedAt: Double?
        while ContinuousClock.now < deadline {
            let applied = await connection.appliedBytes
            let received = await connection.receivedBytes
            if applied == state.outputBytes, received == state.outputBytes {
                let snapshot = await connection.snapshot()
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
                    guard let accepted, let frame = lastFrame else { throw Failure("The pane has no rendered checkpoint yet.") }
                    if let copiedAt, frame.submittedAt < copiedAt { throw Failure("Waiting for the native selection highlight.") }
                    if expected.lifecycle?.resumed == true {
                        // The connection resets its parser at ready(true). Keep the last
                        // coherent native frame on screen until the serialized replay arrives.
                        try expected.verify(snapshot)
                        guard let previous = lastCheckpoint, accepted.generation == frame.generation else {
                            throw Failure("The pane lost its pre-detach frame while waiting for replay.")
                        }
                        try previous.verify(accepted)
                    } else {
                        try WorkflowCheckpoint.verify(expected, snapshot: snapshot, nativePalette: view.resolvedTheme.palette,
                                                      accepted: accepted, renderedGeneration: frame.generation, copiedText: copied)
                    }
                    return Entry(name: expected.name, eventIndex: state.eventIndex, columns: snapshot.size.columns,
                                 rows: snapshot.size.rows, receivedBytes: received, appliedBytes: applied,
                                 attachments: state.attachments, generation: snapshot.generation,
                                 acceptedGeneration: accepted.generation, renderedGeneration: frame.generation,
                                 synchronized: snapshot.synchronizedOutputID != nil, hasPresentationTime: lastTimedSubmission == frame.submittedAt,
                                 copiedText: copied)
                } catch { detail = String(describing: error) }
            } else {
                detail = "peer sent \(state.outputBytes), connection received \(received) and applied \(applied)"
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

    private func capture(_ entry: Entry, endedNotice: Bool) async throws {
        var notice: VisiblePaneNotice?
        if endedNotice {
            let until = ContinuousClock.now.advanced(by: .seconds(12))
            var previous: CGRect?
            var unchangedSince = ContinuousClock.now
            while ContinuousClock.now < until {
                if let panel = view.visiblePaneNotice, panel.title == "Ended", panel.action == "New Shell" {
                    try await NativeWorkflowActions.verifyKeyboardDown(view)
                    if let settled = view.visiblePaneNotice, settled.title == panel.title, settled.action == panel.action,
                       lastFrame?.drawableSize == view.drawableSize {
                        if settled.frameInWindow != previous {
                            previous = settled.frameInWindow
                            unchangedSince = .now
                        } else if unchangedSince.duration(to: .now) >= .milliseconds(500) {
                            notice = settled
                            break
                        }
                    }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard notice != nil else { throw Failure("No settled Ended panel and completed drawable for the final shell.") }
            guard shell.hasExited else { throw Failure("The final shell has not published its exit.") }
        }
        let base = String(format: "capture-%03d", entry.eventIndex)
        guard let accepted = view.snapshot, accepted.generation == entry.acceptedGeneration,
              let frame = lastFrame, frame.generation == entry.renderedGeneration else {
            throw Failure("Missing the submitted grid for " + entry.name)
        }
        // UIKit may finish moving the keyboard after Metal completes the unchanged final drawable.
        // Map its actual submitted pixels through the settled window geometry before capturing.
        let layout: WorkflowCapture.Layout
        if endedNotice {
            guard frame.drawableSize == view.drawableSize,
                  let settled = WorkflowCapture.Layout(view: view, drawableGrid: frame.drawableGrid) else {
                throw Failure("Final framebuffer geometry changed before capture.")
            }
            layout = settled
        } else {
            layout = frame.layout
        }
        let marker = WorkflowCapture(name: entry.name, eventIndex: entry.eventIndex, view: view,
                                     snapshot: accepted, layout: layout, copied: entry.copiedText, endedNotice: notice)
        try save(marker, as: base + ".json")
        let ack = output.appending(path: base + ".done")
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !FileManager.default.fileExists(atPath: ack.path) {
            guard ContinuousClock.now < deadline else { throw Failure("No native screenshot for " + entry.name) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func save(_ value: some Encodable, as name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: output.appending(path: name), options: .atomic)
    }
}
