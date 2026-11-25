import Foundation
import QuartzCore
import Thrush

#if os(iOS)
import UIKit
#endif

/// Captures frames submitted by the native demo while its responder runs the recorded clear.
@MainActor
enum ClearCapture {
    static func start(in view: TerminalView, output: URL) {
        Task {
            var frames = [[String: Any]]()
            let submit = view.onFrameSubmitted
            view.onFrameSubmitted = { time, size, grid in
                submit?(time, size, grid)
                guard let snapshot = view.snapshot, let layout = WorkflowCapture.Layout(view: view, drawableGrid: grid) else { return }
                var frame: [String: Any] = [
                    "time": time, "generation": snapshot.generation, "history": snapshot.history.count,
                    "offset": view.historyOffset, "cursor": [snapshot.cursorRow, snapshot.cursorColumn],
                    "cursorVisible": snapshot.cursorVisible, "text": snapshot.rows.map(\.text),
                    "columns": snapshot.size.columns, "rows": snapshot.size.rows,
                    "grid": layout.gridInWindow, "window": layout.windowSize,
                ]
                #if os(iOS)
                if let scroll = view.subviews.flatMap(\.subviews).compactMap({ $0 as? UIScrollView }).first {
                    frame["scrollHeight"] = scroll.contentSize.height
                    frame["scrollY"] = scroll.contentOffset.y
                    frame["viewportHeight"] = scroll.bounds.height
                }
                frame["keyboardHeight"] = layout.keyboard?.keyboardHeight
                #endif
                frames.append(frame)
            }
            defer { view.onFrameSubmitted = submit }
            func write(_ name: String, _ data: Data = Data()) throws {
                try data.write(to: output.appending(path: name), options: .atomic)
            }
            @MainActor func wait(_ condition: @MainActor () -> Bool) async throws {
                let limit = ContinuousClock.now + .seconds(90)
                while !condition() {
                    try await Task.sleep(for: .milliseconds(20))
                    if ContinuousClock.now >= limit { throw RenderBenchmark.Failure("Timed out waiting for the clear recording.") }
                }
            }
            func marker(_ name: String) -> Bool {
                FileManager.default.fileExists(atPath: output.appending(path: name).path)
            }
            do {
                try await wait { (view.snapshot?.history.count ?? 0) > 20 && !frames.isEmpty }
                try write("ready")
                try await wait { marker("type") }
                try NativeWorkflowActions.input(.text("clear"), view: view)
                try await wait { marker("return") }
                try NativeWorkflowActions.input(.key(.enter), view: view)
                try await wait { marker("finish") }
                try write("frames.json", JSONSerialization.data(withJSONObject: frames))
            } catch {
                try? write("error.txt", Data(String(describing: error).utf8))
            }
        }
    }
}
