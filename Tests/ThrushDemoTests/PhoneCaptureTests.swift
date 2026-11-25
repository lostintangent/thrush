import Foundation
import Testing
import ThrushCore
@testable import ThrushDemo
@testable import Thrush

@Test @MainActor func keyboardCanSettleAroundAnUnchangedCompletedDrawable() throws {
    let size = Terminal.Size(columns: 47, rows: 25)
    let pixels = CGSize(width: 1206, height: 1401)
    let cells = CGRect(x: 30, y: 24, width: 1133, height: 1350)
    var layout = PhoneCapture.State(scene: "editor", appearance: "dark", orientation: "portrait", pid: 1,
        columns: 47, rows: 25, windowPoints: CGRect(x: 0, y: 0, width: 402, height: 874),
        gridFrame: CGRect(x: 0, y: 61, width: 402, height: 466), displayScale: 3,
        keyboardHeight: 301, accessoryHeight: 0, selection: nil)
    func drawing(generation: UInt64 = 7, theme: TerminalTheme = .slateDark) -> PhoneCapture.Drawing? {
        PhoneCapture.Drawing(state: layout, generation: generation, size: size, drawableSize: pixels,
                             fontSize: nil, theme: theme, historyOffset: 0)
    }
    func completion(at time: Double) -> FrameMeasurement {
        FrameMeasurement(generation: 7, gpuCompleted: true, cpuPreparationSeconds: 0, shaderCompileSeconds: nil,
                         firstFrameSeconds: nil, gpuSeconds: nil, presentedTime: nil, receivedAt: nil,
                         submittedAt: time, glyphUploads: 14, rowsPrepared: 25)
    }

    var submission = PhoneCapture.Submission(time: 2, drawing: try #require(drawing()), cells: cells)
    layout.keyboardHeight = 345
    layout.accessoryHeight = 44
    submission.complete(completion(at: 1))
    #expect(!submission.applying(to: layout, drawing: drawing()).gpuCompleted)
    submission.complete(completion(at: 2))
    #expect(!submission.applying(to: layout, drawing: drawing()).gpuCompleted)
    layout.gridFrame = CGRect(x: 0, y: 62, width: 402, height: 467)
    let settled = submission.applying(to: layout, drawing: drawing())
    #expect(settled.gpuCompleted && settled.generation == 7)
    #expect(settled.rowsPrepared == 25 && settled.glyphUploads == 14)
    #expect(settled.cellGridPixels == cells && settled.gridFrame.origin.y == 62)
    #expect(settled.keyboardHeight == 345 && settled.accessoryHeight == 44)

    #expect(!submission.applying(to: layout, drawing: drawing(generation: 8)).gpuCompleted)
    #expect(!submission.applying(to: layout, drawing: drawing(theme: .slateLight)).gpuCompleted)
    layout.gridFrame.size.height += 1
    #expect(!submission.applying(to: layout, drawing: drawing()).gpuCompleted)
}
