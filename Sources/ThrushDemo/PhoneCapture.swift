import Foundation
import Thrush
#if os(iOS)
import UIKit
#endif

/// Opt-in metadata for simulator captures. The screenshot oracle checks the framebuffer separately.
@MainActor
enum PhoneCapture {
    struct Toolbar: Encodable, Equatable {
        let canvasFrame, safeAreaFrame, navigationBarFrame, firstCellFrame: CGRect
    }

    struct State: Encodable, Equatable {
        let scene, appearance, orientation: String
        let pid: Int32
        var generation: UInt64 = 0
        var gpuCompleted = false
        var rowsPrepared = 0, glyphUploads = 0
        var cellGridPixels: CGRect?
        let columns, rows: Int
        var windowPoints, gridFrame: CGRect
        let displayScale: CGFloat
        var keyboardHeight, accessoryHeight: CGFloat
        /// The key row's controls, left to right, in `windowPoints` coordinates.
        var keys: [CGRect] = []
        let selection: [Int]?
        var cursorSpinner: CGRect?
        var cursorSpinnerLabel: String?
        var cursorCellFrame, firstCellFrame: CGRect?
        var keyboardLanguage: String?
        var toolbar: Toolbar?
        var reducesMotion = false
        var historyOffset = 0
    }

    /// UIKit can move the completed drawable or its keyboard without changing a pixel inside it.
    struct Drawing: Equatable {
        let scene: String
        let generation: UInt64
        let size: Terminal.Size
        let drawableSize: CGSize
        let scale: CGFloat
        let fontSize: CGFloat?
        let theme: TerminalTheme
        let selection: [Int]?
        let historyOffset: Int

        init?(state: State, generation: UInt64?, size: Terminal.Size?, drawableSize: CGSize,
              fontSize: CGFloat?, theme: TerminalTheme, historyOffset: Int) {
            guard let generation, let size else { return nil }
            self.scene = state.scene
            self.generation = generation
            self.size = size
            self.drawableSize = drawableSize
            self.scale = state.displayScale
            self.fontSize = fontSize
            self.theme = theme
            self.selection = state.selection
            self.historyOffset = historyOffset
        }

        func fits(_ state: State) -> Bool {
            size.columns == state.columns && size.rows == state.rows
                && (state.gridFrame.width * scale).rounded() == drawableSize.width
                && (state.gridFrame.height * scale).rounded() == drawableSize.height
        }
    }

    struct Submission {
        let time: Double
        let drawing: Drawing
        let cells: CGRect
        var measurement: FrameMeasurement?

        mutating func complete(_ frame: FrameMeasurement) {
            guard frame.submittedAt == time, frame.gpuCompleted, frame.generation == drawing.generation else { return }
            measurement = frame
        }

        func applying(to state: State, drawing current: Drawing?) -> State {
            guard current == drawing, drawing.fits(state), let measurement else { return state }
            var state = state
            state.generation = measurement.generation
            state.gpuCompleted = true
            state.rowsPrepared = measurement.rowsPrepared
            state.glyphUploads = measurement.glyphUploads
            state.cellGridPixels = cells
            return state
        }
    }

    #if os(iOS)
    static func observe(_ session: DemoSession, view: TerminalMetalView, in root: UIView) -> (() -> Void)? {
        guard CommandLine.arguments.contains("--capture-state") else { return nil }
        let destination = URL.documentsDirectory.appending(path: "capture-state.json")
        let accessibility = PhoneAccessibilityCapture(scene: session.options.scene, view: view)
        let layout: () -> (state: State, drawing: Drawing?)? = { [weak session, weak view, weak root] in
            guard let session, let view, let root, let scene = root.window?.windowScene, !root.bounds.isEmpty else { return nil }
            let appearance = view.resolvedTheme == .slateDark ? "dark" : view.resolvedTheme == .slateLight ? "light" : "custom"
            let selection = view.selection.map { [$0.anchorRow, $0.anchorColumn, $0.headRow, $0.headColumn] }
            let input = view.subviews.first(where: \.isFirstResponder)
            let accessory = input?.inputAccessoryView
            var state = State(scene: session.options.scene.rawValue, appearance: appearance,
                orientation: scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait",
                pid: ProcessInfo.processInfo.processIdentifier,
                columns: view.gridSize?.columns ?? 0, rows: view.gridSize?.rows ?? 0,
                windowPoints: root.bounds, gridFrame: view.convert(view.bounds, to: root),
                displayScale: view.traitCollection.displayScale, keyboardHeight: root.keyboardLayoutGuide.layoutFrame.height,
                accessoryHeight: accessory?.window == nil ? 0 : accessory?.bounds.height ?? 0,
                keys: keyFrames(of: accessory, in: root), selection: selection)
            if session.options.scene.capturesSessionState {
                state.cursorSpinner = view.cursorSpinnerFrameInWindow
                state.cursorSpinnerLabel = view.subviews.first {
                    $0 is UIActivityIndicatorView && !$0.isHidden && $0.isAccessibilityElement
                        && $0.accessibilityIdentifier == "terminal.cursorSpinner"
                }?.accessibilityLabel
                state.cursorCellFrame = view.cursorCellFrameInWindow
                state.firstCellFrame = view.cellFrameInWindow(row: 0, column: 0)
                state.keyboardLanguage = input?.textInputMode?.primaryLanguage
            }
            if session.options.checksToolbar { state.toolbar = PhoneToolbarProof.measure(view) }
            state.reducesMotion = view.reducesMotion
            state.historyOffset = view.historyOffset
            let drawing = Drawing(state: state, generation: view.snapshot?.generation, size: view.snapshot?.size,
                                  drawableSize: view.drawableSize, fontSize: view.fontSize,
                                  theme: view.resolvedTheme, historyOffset: view.historyOffset)
            return (state, drawing)
        }
        var lastWritten: State?
        func write(_ state: State) {
            guard state != lastWritten else { return }
            accessibility?.observe(state)
            do {
                try JSONEncoder().encode(state).write(to: destination, options: .atomic)
                lastWritten = state
            } catch {
                FileHandle.standardError.write(Data("Could not record capture state: \(error)\n".utf8))
            }
        }
        var latest: Submission?
        func writeLatest() {
            guard let current = layout() else { return }
            write(latest?.applying(to: current.state, drawing: current.drawing) ?? current.state)
        }
        view.onFrameSubmitted = { time, size, cells in
            latest = nil
            guard let current = layout() else { return }
            if let drawing = current.drawing, drawing.size == size {
                latest = Submission(time: time, drawing: drawing, cells: cells)
            }
            write(current.state)
        }
        view.onFrame = { frame in
            latest?.complete(frame)
            writeLatest()
        }
        return writeLatest
    }

    /// The accessory lives in the keyboard's window, so its controls convert through the scene.
    static func keyFrames(of accessory: UIView?, in root: UIView) -> [CGRect] {
        guard let accessory, accessory.window != nil, let scene = root.window?.windowScene?.coordinateSpace else { return [] }
        func buttons(in view: UIView) -> [UIButton] {
            view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons(in: $0) }
        }
        return buttons(in: accessory).filter { !$0.isHidden }
            .map { root.convert($0.convert($0.bounds, to: scene), from: scene) }
            .sorted { $0.minX < $1.minX }
    }

    static func orient(_ scene: UIScene) {
        guard CommandLine.arguments.contains("--capture-landscape"), let window = scene as? UIWindowScene,
              !window.effectiveGeometry.interfaceOrientation.isLandscape else { return }
        window.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
            FileHandle.standardError.write(Data("Landscape capture request failed: \(error)\n".utf8))
        }
    }
    #endif
}
