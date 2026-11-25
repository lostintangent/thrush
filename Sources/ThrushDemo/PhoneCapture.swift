#if os(iOS)
import ThrushUI
import UIKit

/// Opt-in metadata for simulator captures. The screenshot oracle checks the framebuffer separately.
@MainActor
enum PhoneCapture {
    private struct State: Encodable {
        let scene, appearance, orientation: String
        let pid: Int32
        let generation: UInt64
        let gpuCompleted: Bool
        let columns, rows, rowsPrepared, glyphUploads: Int
        let windowPoints, gridFrame: CGRect
        let displayScale, keyboardHeight, accessoryHeight: CGFloat
        let selection: [Int]?
    }

    static func observe(_ session: DemoSession, in root: UIView, input: UIResponder) -> (() -> Void)? {
        guard CommandLine.arguments.contains("--capture-state") else { return nil }
        let destination = URL.documentsDirectory.appending(path: "capture-state.json")
        let write: (FrameMeasurement?) -> Void = { [weak session, weak root, weak input] frame in
            guard let session, let root, let scene = root.window?.windowScene, !root.bounds.isEmpty else { return }
            let size = session.view.gridSize
            let view = session.view
            let appearance = view.resolvedTheme == .slateDark ? "dark" : view.resolvedTheme == .slateLight ? "light" : "custom"
            let selection = view.selection.map { [$0.anchorRow, $0.anchorColumn, $0.headRow, $0.headColumn] }
            let accessory = input?.inputAccessoryView
            let state = State(scene: session.options.scene.rawValue, appearance: appearance,
                orientation: scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait",
                pid: ProcessInfo.processInfo.processIdentifier, generation: frame?.generation ?? 0, gpuCompleted: frame != nil,
                columns: size?.columns ?? 0, rows: size?.rows ?? 0,
                rowsPrepared: frame?.rowsPrepared ?? 0, glyphUploads: frame?.glyphUploads ?? 0,
                windowPoints: root.bounds, gridFrame: view.convert(view.bounds, to: root),
                displayScale: view.traitCollection.displayScale, keyboardHeight: root.keyboardLayoutGuide.layoutFrame.height,
                accessoryHeight: accessory?.window == nil ? 0 : accessory?.bounds.height ?? 0, selection: selection)
            do {
                try JSONEncoder().encode(state).write(to: destination, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Could not record capture state: \(error)\n".utf8))
            }
        }
        var latestFrame: FrameMeasurement?
        session.view.onFrame = { frame in
            latestFrame = frame
            write(frame)
        }
        // A native-only scene can settle before the terminal has any content to draw.
        return { write(latestFrame) }
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
