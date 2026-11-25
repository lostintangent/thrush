#if os(iOS)
import ThrushUI
import UIKit

/// Opt-in metadata for simulator captures. The screenshot oracle checks the framebuffer separately.
@MainActor
enum PhoneCapture {
    private struct State: Encodable, Equatable {
        let scene, appearance, orientation: String
        let pid: Int32
        var generation: UInt64 = 0
        var gpuCompleted = false
        var rowsPrepared = 0, glyphUploads = 0
        var cellGridPixels: CGRect?
        let columns, rows: Int
        let windowPoints, gridFrame: CGRect
        let displayScale, keyboardHeight, accessoryHeight: CGFloat
        let selection: [Int]?
    }

    static func observe(_ session: DemoSession, in root: UIView, input: UIResponder) -> (() -> Void)? {
        guard CommandLine.arguments.contains("--capture-state") else { return nil }
        let destination = URL.documentsDirectory.appending(path: "capture-state.json")
        let layout: () -> State? = { [weak session, weak root, weak input] in
            guard let session, let root, let scene = root.window?.windowScene, !root.bounds.isEmpty else { return nil }
            let view = session.view
            let appearance = view.resolvedTheme == .slateDark ? "dark" : view.resolvedTheme == .slateLight ? "light" : "custom"
            let selection = view.selection.map { [$0.anchorRow, $0.anchorColumn, $0.headRow, $0.headColumn] }
            let accessory = input?.inputAccessoryView
            return State(scene: session.options.scene.rawValue, appearance: appearance,
                orientation: scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait",
                pid: ProcessInfo.processInfo.processIdentifier,
                columns: view.gridSize?.columns ?? 0, rows: view.gridSize?.rows ?? 0,
                windowPoints: root.bounds, gridFrame: view.convert(view.bounds, to: root),
                displayScale: view.traitCollection.displayScale, keyboardHeight: root.keyboardLayoutGuide.layoutFrame.height,
                accessoryHeight: accessory?.window == nil ? 0 : accessory?.bounds.height ?? 0, selection: selection)
        }
        func write(_ state: State) {
            do {
                try JSONEncoder().encode(state).write(to: destination, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Could not record capture state: \(error)\n".utf8))
            }
        }
        var pending: (time: Double, layout: State, cells: CGRect)?
        var completed: State?
        session.view.onFrameSubmitted = { time, size, cells in
            completed = nil
            guard let state = layout() else { pending = nil; return }
            pending = size?.columns == state.columns && size?.rows == state.rows ? (time, state, cells) : nil
            write(state)
        }
        session.view.onFrame = { frame in
            guard let pending, frame.gpuCompleted, frame.submittedAt == pending.time,
                  layout() == pending.layout else { return }
            var state = pending.layout
            state.generation = frame.generation
            state.gpuCompleted = true
            state.rowsPrepared = frame.rowsPrepared
            state.glyphUploads = frame.glyphUploads
            state.cellGridPixels = pending.cells
            completed = state
            write(state)
        }
        // A native-only scene can settle before the terminal has content. Changing host
        // geometry invalidates the previous result until that geometry completes on the GPU.
        return {
            guard let state = layout() else { return }
            if let pending, pending.layout == state, let completed {
                write(completed)
            } else {
                write(state)
            }
        }
    }

    static func orient(_ scene: UIScene) {
        guard CommandLine.arguments.contains("--capture-landscape"), let window = scene as? UIWindowScene,
              !window.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        window.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
            FileHandle.standardError.write(Data("Landscape capture request failed: \(error)\n".utf8))
        }
    }
}
#endif
