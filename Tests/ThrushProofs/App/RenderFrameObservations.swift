import QuartzCore
import Thrush

/// Observe the finite packaged-renderer workload. A GPU result can arrive even when
/// the window server never calls the drawable's presentation handler.
@MainActor
final class RenderFrameObservations {
    private let view: TerminalMetalView
    private var completions: [FrameMeasurement] = []
    private var presentations: [Double: FrameMeasurement] = [:]
    private var waitsForPresentation = true
    private let previousFrame: ((FrameMeasurement) -> Void)?
    private let previousCompletion: (@MainActor (FrameMeasurement) -> Void)?

    init(view: TerminalMetalView) {
        self.view = view
        previousFrame = view.onFrame
        previousCompletion = view.onFrameCompleted
        view.onFrameCompleted = { [weak self] frame in
            self?.previousCompletion?(frame)
            self?.completions.append(frame)
        }
        view.onFrame = { [weak self] frame in
            guard let self else { return }
            previousFrame?(frame)
            presentations[frame.submittedAt] = frame
            waitsForPresentation = frame.presentedTime != nil
        }
    }

    func stop() {
        view.onFrame = previousFrame
        view.onFrameCompleted = previousCompletion
    }

    func completions(since start: Double) -> [FrameMeasurement] {
        completions.filter { $0.submittedAt >= start }
    }

    /// The frame as last reported, with its drawable presentation time once one arrived.
    func presented(_ frame: FrameMeasurement) throws -> FrameMeasurement {
        guard let presented = presentations[frame.submittedAt], let time = presented.presentedTime else { return frame }
        guard time.isFinite, time >= frame.submittedAt else {
            throw RenderBenchmark.Failure("Invalid drawable presentation time for submission \(frame.submittedAt).")
        }
        return presented
    }

    func frame(for operation: String, generation: UInt64, after start: Double, receivedAt receipt: Double? = nil,
               initialSubmissions: Int) async throws -> FrameMeasurement {
        let deadline = start + 15
        while true {
            if let frame = completions.first(where: {
                $0.generation == generation && $0.submittedAt >= start && (receipt == nil || $0.receivedAt == receipt)
            }) {
                guard frame.gpuCompleted else { throw RenderBenchmark.Failure("GPU command failed for \(operation), generation \(generation).") }
                // Pace a visible window to its actual presentations. An unresponsive display
                // pays one grace interval; later positive timestamps re-enable pacing.
                let grace = CACurrentMediaTime() + 0.25
                while waitsForPresentation, presentations[frame.submittedAt] == nil {
                    if CACurrentMediaTime() >= grace {
                        waitsForPresentation = false
                        break
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
                return frame
            }
            guard CACurrentMediaTime() < deadline else {
                let recent = completions.filter { $0.submittedAt >= start }
                let last = recent.last.map { "generation \($0.generation), receipt \(String(describing: $0.receivedAt))" } ?? "none"
                throw RenderBenchmark.Failure("No GPU result for \(operation), generation \(generation). "
                    + "Submissions \(view.submissionCount - initialSubmissions), GPU completions \(recent.count), last \(last).")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
