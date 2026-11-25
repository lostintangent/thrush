import QuartzCore
import Testing
@testable import ThrushDemo
@testable import ThrushUI

@Test @MainActor func renderSampleSurvivesAnUnmarkedRedrawOfTheSameGeneration() async throws {
    let view = TerminalView(frame: .zero)
    let receipt = CACurrentMediaTime()
    func frame(receivedAt: Double?, uploads: Int) -> FrameMeasurement {
        FrameMeasurement(generation: 7, gpuCompleted: true, cpuPreparationSeconds: 0, shaderCompileSeconds: nil,
                         firstFrameSeconds: nil, gpuSeconds: nil, presentedTime: nil, receivedAt: receivedAt,
                         submittedAt: CACurrentMediaTime(), glyphUploads: uploads, rowsPrepared: 24)
    }
    let measured = try await RenderBenchmark.measureFrame(on: view, for: "cold", generation: 7,
                                                          after: receipt, receivedAt: receipt) {
        view.onFrame?(frame(receivedAt: nil, uploads: 0))
        view.onFrame?(frame(receivedAt: receipt, uploads: 14))
        view.onFrame?(frame(receivedAt: nil, uploads: 0))
    }
    #expect(measured.receivedAt == receipt)
    #expect(measured.glyphUploads == 14)
    #expect(view.onFrame == nil)
}
