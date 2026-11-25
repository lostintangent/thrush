import QuartzCore
import Testing
@testable import ThrushDemo
@testable import Thrush

private func frame(_ submission: Double, receivedAt: Double? = nil, presentedTime: Double? = nil,
                   completed: Bool = true) -> FrameMeasurement {
    FrameMeasurement(generation: 7, gpuCompleted: completed, cpuPreparationSeconds: 0.001, shaderCompileSeconds: nil,
                     firstFrameSeconds: nil, gpuSeconds: 0.002, presentedTime: presentedTime, receivedAt: receivedAt,
                     submittedAt: submission, glyphUploads: 14, rowsPrepared: 24)
}

@Test @MainActor func renderSampleSurvivesAnUnmarkedRedrawOfTheSameGeneration() async throws {
    let view = TerminalView(frame: .zero)
    let observations = RenderFrameObservations(view: view)
    defer { observations.stop() }
    let receipt = CACurrentMediaTime()
    let content = frame(receipt, receivedAt: receipt)
    view.onFrameCompleted?(frame(receipt - 0.001))
    view.onFrameCompleted?(content)
    view.onFrameCompleted?(frame(receipt + 0.001))
    let measured = try await observations.frame(for: "cold", generation: 7, after: receipt, receivedAt: receipt, initialSubmissions: 0)
    #expect(measured.receivedAt == receipt && measured.gpuSeconds == 0.002)
    #expect(try observations.presentationTime(for: measured.submittedAt) == nil)

    let actual = receipt + 0.025
    view.onFrame?(frame(receipt, receivedAt: receipt, presentedTime: actual))
    #expect(try observations.presentationTime(for: measured.submittedAt) == actual)
    #expect(try observations.presentationTime(for: receipt + 0.001) == nil)
}

@Test @MainActor func rendererRequiresSuccessfulGPUCompletionEvenWhenAPresentationIsDelivered() async throws {
    let view = TerminalView(frame: .zero)
    let observations = RenderFrameObservations(view: view)
    defer { observations.stop() }
    let start = CACurrentMediaTime() - 16
    let content = frame(start, receivedAt: start, presentedTime: start + 0.02)
    view.onFrame?(content)
    await #expect(throws: RenderBenchmark.Failure.self) {
        try await observations.frame(for: "cold", generation: 7, after: start, receivedAt: start, initialSubmissions: 0)
    }
    view.onFrameCompleted?(frame(start, receivedAt: start, completed: false))
    await #expect(throws: RenderBenchmark.Failure.self) {
        try await observations.frame(for: "cold", generation: 7, after: start, receivedAt: start, initialSubmissions: 0)
    }
    let later = start + 0.01
    view.onFrame?(frame(later, receivedAt: later, presentedTime: later + 0.015))
    view.onFrameCompleted?(frame(later, receivedAt: later))
    let measured = try await observations.frame(for: "full", generation: 7, after: later, receivedAt: later, initialSubmissions: 0)
    #expect(try observations.presentationTime(for: measured.submittedAt) == later + 0.015)
}
