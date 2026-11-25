import Thrush
import ThrushReplay

/// Checks a paused workflow against the pinned xterm recording and the running pane.
package enum WorkflowCheckpoint {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Sample all three generations within one attachment. The live model keeps parsing during
    /// a synchronized repaint, while the previous coherent frame may still be in flight.
    /// On Simulator the frame callback observes GPU completion in place of drawable presentation.
    package static func verify(
        _ event: ReplayFixture.Event,
        snapshot: Terminal.Snapshot,
        nativePalette: Terminal.Palette,
        accepted: Terminal.Snapshot?,
        presentedGeneration: UInt64?,
        copiedText: String? = nil
    ) throws {
        func failure(_ message: String) -> Failure { Failure(description: "\(event.name): \(message)") }

        guard event.checkpoint != nil else { throw failure("missing recorded checkpoint") }
        try event.verify(snapshot)
        guard snapshot.palette == nativePalette else { throw failure("terminal palette differs from the native view") }

        guard let accepted else { throw failure("the native pane has not accepted a snapshot") }
        guard let presentedGeneration else { throw failure("the native pane has not rendered a frame") }
        if snapshot.synchronizedOutputID != nil {
            guard accepted.synchronizedOutputID == nil, accepted.generation < snapshot.generation,
                  presentedGeneration <= accepted.generation else {
                throw failure("synchronized repaint at \(snapshot.generation) must retain a coherent frame, accepted \(accepted.generation), presented \(presentedGeneration)")
            }
        } else {
            guard accepted.generation == snapshot.generation, presentedGeneration == snapshot.generation else {
                throw failure("expected frame \(snapshot.generation), accepted \(accepted.generation), presented \(presentedGeneration)")
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
