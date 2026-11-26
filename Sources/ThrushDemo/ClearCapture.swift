import Foundation
import QuartzCore
import Thrush

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Captures frames submitted by the native demo while its responder runs the recorded clear.
/// Without typing, it records every submission until the driver finishes a peer-paced burst run.
@MainActor
enum ClearCapture {
    private struct Submission {
        let time: Double
        let snapshot: Terminal.Snapshot
        let offset: Int
        let layout: WorkflowCapture.Layout
        var extras: [String: Any] = [:]

        var json: [String: Any] {
            var frame: [String: Any] = [
                "time": time, "generation": snapshot.generation, "history": snapshot.history.count,
                "offset": offset, "cursor": [snapshot.cursorRow, snapshot.cursorColumn],
                "cursorVisible": snapshot.cursorVisible, "text": snapshot.rows.map(\.text),
                "columns": snapshot.size.columns, "rows": snapshot.size.rows,
                "grid": layout.gridInWindow, "window": layout.windowSize,
            ]
            frame.merge(extras) { _, new in new }
            return frame
        }
    }

    static func start(in view: TerminalView, output: URL, typesClear: Bool = true) {
        Task {
            // Keep each submitted snapshot and convert its text after the run, so the
            // capture adds as little work as possible before the drawable is presented.
            var frames = [Submission]()
            let submit = view.onFrameSubmitted
            view.onFrameSubmitted = { time, size, grid in
                submit?(time, size, grid)
                guard let snapshot = view.snapshot, let layout = WorkflowCapture.Layout(view: view, drawableGrid: grid) else { return }
                var frame = Submission(time: time, snapshot: snapshot, offset: view.historyOffset, layout: layout)
                #if os(iOS)
                if let scroll = view.subviews.flatMap(\.subviews).compactMap({ $0 as? UIScrollView }).first {
                    frame.extras["scrollHeight"] = scroll.contentSize.height
                    frame.extras["scrollY"] = scroll.contentOffset.y
                    frame.extras["viewportHeight"] = scroll.bounds.height
                }
                frame.extras["keyboardHeight"] = layout.keyboard?.keyboardHeight
                #endif
                frames.append(frame)
            }
            defer { view.onFrameSubmitted = submit }
            func write(_ name: String, _ data: Data = Data()) throws {
                try data.write(to: output.appending(path: name), options: .atomic)
            }
            // The driver bounds a burst run itself, since a loaded runner can pace it slowly.
            @MainActor func wait(for seconds: Int = 90, _ condition: @MainActor () -> Bool) async throws {
                let limit = ContinuousClock.now + .seconds(seconds)
                while !condition() {
                    try await Task.sleep(for: .milliseconds(20))
                    if ContinuousClock.now >= limit { throw RenderBenchmark.Failure("Timed out waiting for the clear recording.") }
                }
            }
            func marker(_ name: String) -> Bool {
                FileManager.default.fileExists(atPath: output.appending(path: name).path)
            }
            do {
                #if os(macOS)
                try await wait { view.window?.isVisible == true }
                let window = view.window!
                let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
                    "windowID": window.windowNumber, "key": window.isKeyWindow, "active": NSApp.isActive,
                    "occluded": !window.occlusionState.contains(.visible)]
                try write("ready", JSONSerialization.data(withJSONObject: state))
                #else
                try await wait { (!typesClear || (view.snapshot?.history.count ?? 0) > 20) && !frames.isEmpty }
                try write("ready")
                #endif
                if typesClear {
                    try await wait { marker("type") }
                    try NativeWorkflowActions.input(.text("clear"), view: view)
                    try await wait { marker("return") }
                    try NativeWorkflowActions.input(.key(.enter), view: view)
                }
                try await wait(for: typesClear ? 90 : 600) { marker("finish") }
                try write("frames.json", JSONSerialization.data(withJSONObject: frames.map(\.json)))
            } catch {
                try? write("error.txt", Data(String(describing: error).utf8))
            }
        }
    }
}
