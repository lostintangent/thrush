import Foundation
import ThrushCore

// A reader who falls behind or reconnects gets one replay in place of the output it missed, so a replay
// has to rebuild everything the live terminal holds: what a checkpoint shows, and the state that only
// shows through later output. The check resumes a terminal from ThrushCore's replay after every write
// and resize of a case, and holds it to the live terminal from then on.

extension ConformanceCase {
    /// ThrushCore's replay after one step, and where a terminal resumed from it first differs from the live one.
    struct Replay: Encodable {
        /// The index in `steps` of the write or resize the replay follows.
        var step: Int
        var bytes: Data
        var divergence: Divergence?
    }

    /// The first point where a resumed terminal differs from the live one, with every difference there.
    struct Divergence: Encodable {
        /// `replay` for right after the replay, `step n` for after a later step, or `end`.
        var at: String
        var differences: [String]
    }

    /// Resumes a terminal from ThrushCore's replay after every write and resize, and compares it with the
    /// live terminal right away, after each later step and at the end.
    ///
    /// Right away and at the end, the comparison includes history and the normal screen behind the
    /// alternate one, and what `probe` shows on a copy of each terminal. The probe asks and prints whatever
    /// reveals the state a checkpoint can't show, such as the saved cursor or tab stops, in parts that
    /// each end with a visible checkpoint.
    func replays(probe: [[UInt8]]) -> [Replay] {
        // The live terminal after each step that acts on it, with what that step showed.
        var terminal = Terminal(size: Terminal.Size(columns: size[0], rows: size[1]), palette: thrushPalette)
        var live: [(step: Int, terminal: Terminal, shown: Checkpoint)] = []
        for (index, step) in steps.enumerated() {
            if case .checkpoint = step { continue }
            let replies = terminal.perform(step)
            live.append((index, terminal, Checkpoint(terminal, name: "step \(index)", includesHistory: false, replies: replies)))
        }
        let end = Self.state(of: terminal, at: "end", probe: probe)

        return live.indices.compactMap { position in
            let point = live[position]
            switch steps[point.step] {
            case .write, .resize: break
            default: return nil
            }
            let bytes = point.terminal.replayBytes()
            var resumed = point.terminal
            resumed.prepareForReplay(at: resumed.size)
            let replies = resumed.write(bytes)
            // Turning focus reporting on reports focus, so the program hears the resumed client's focus.
            let report = point.terminal.encode(.focus(point.terminal.isFocused))
            func divergence() -> Divergence? {
                var differences = replies == report ? [] :
                    ["replies: live \(Checkpoint.printable(report)), resumed \(Checkpoint.printable(replies))"]
                differences += Self.differences(Self.state(of: resumed, at: "replay", probe: probe),
                                                from: Self.state(of: point.terminal, at: "replay", probe: probe))
                if !differences.isEmpty { return Divergence(at: "replay", differences: differences) }
                for later in live[(position + 1)...] {
                    let replies = resumed.perform(steps[later.step])
                    let shown = Checkpoint(resumed, name: later.shown.name, includesHistory: false, replies: replies)
                    if shown != later.shown {
                        return Divergence(at: later.shown.name, differences: Self.differences([shown], from: [later.shown]))
                    }
                }
                let atEnd = Self.differences(Self.state(of: resumed, at: "end", probe: probe), from: end)
                return atEnd.isEmpty ? nil : Divergence(at: "end", differences: atEnd)
            }
            return Replay(step: point.step, bytes: Data(bytes), divergence: divergence())
        }
    }

    /// A terminal's full checkpoint, then the checkpoint each part of `probe` leaves on a copy.
    private static func state(of terminal: Terminal, at name: String, probe: [[UInt8]]) -> [Checkpoint] {
        var probed = terminal
        return [Checkpoint(terminal, name: name, includesHistory: true, replies: [])] + probe.indices.map { part in
            let replies = probed.write(probe[part])
            return Checkpoint(probed, name: "probe \(part + 1)", includesHistory: false, replies: replies)
        }
    }

    /// Each difference as `path: live …, resumed …`, after the name of the probe part that shows it.
    static func differences(_ resumed: [Checkpoint], from live: [Checkpoint]) -> [String] {
        zip(live, resumed).flatMap { live, resumed in
            resumed.differences(from: live).map { difference in
                let part = difference.checkpoint.hasPrefix("probe") ? "\(difference.checkpoint) " : ""
                let (live, resumed) = excerpts(difference.reference, difference.thrush)
                return "\(part)\(difference.path): live \(live), resumed \(resumed)"
            }
        }
    }

    /// Long values, such as a probe's replies, from shortly before where they first differ.
    private static func excerpts(_ first: String, _ second: String, length: Int = 80) -> (String, String) {
        guard first.count > length || second.count > length else { return (first, second) }
        let common = zip(first, second).prefix { $0 == $1 }.count
        let start = max(0, common - length / 4)
        func excerpt(_ text: String) -> String {
            let tail = text.dropFirst(start)
            return (start > 0 ? "…" : "") + tail.prefix(length) + (tail.count > length ? "…" : "")
        }
        return (excerpt(first), excerpt(second))
    }
}
