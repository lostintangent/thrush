import Thrush
import ThrushReplay

/// Checks a paused workflow against the recorded checkpoint and the running pane.
package enum WorkflowCheckpoint {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Sample all three generations within one attachment. The live model keeps parsing during
    /// a synchronized repaint, while the previous coherent frame may still be in flight.
    /// The rendered generation comes from the successful completion of that frame's Metal command buffer.
    package static func verify(
        _ event: ReplayFixture.Event,
        snapshot: Terminal.Snapshot,
        nativePalette: Terminal.Palette,
        accepted: Terminal.Snapshot?,
        renderedGeneration: UInt64?,
        copiedText: String? = nil
    ) throws {
        func failure(_ message: String) -> Failure { Failure(description: "\(event.name): \(message)") }

        guard event.checkpoint != nil else { throw failure("missing recorded checkpoint") }
        try event.verify(snapshot)
        guard snapshot.palette == nativePalette else { throw failure("terminal palette differs from the native view") }

        guard let accepted else { throw failure("the native pane has not accepted a snapshot") }
        guard let renderedGeneration else { throw failure("the native pane has not rendered a frame") }
        if snapshot.synchronizedOutputID != nil {
            guard accepted.synchronizedOutputID == nil, accepted.generation < snapshot.generation,
                  renderedGeneration <= accepted.generation else {
                throw failure("synchronized repaint at \(snapshot.generation) must retain a coherent frame, accepted \(accepted.generation), GPU-completed \(renderedGeneration)")
            }
        } else {
            guard accepted.generation == snapshot.generation, renderedGeneration == snapshot.generation else {
                throw failure("expected frame \(snapshot.generation), accepted \(accepted.generation), GPU-completed \(renderedGeneration)")
            }
            guard accepted.palette == nativePalette else { throw failure("the accepted frame uses a stale palette") }
            try event.verify(accepted)
        }

        if let copy = event.copy {
            guard let copiedText else { throw failure("native copy produced no text") }
            guard copiedText.utf8.elementsEqual(copy.text.utf8) else {
                let offset = zip(copiedText.utf8, copy.text.utf8).prefix(while: { $0 == $1 }).count
                throw failure("native copy differs at UTF-8 byte \(offset), got \(copiedText.debugDescription), expected \(copy.text.debugDescription)")
            }
        }
    }
}
