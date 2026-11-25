# Benchmarks

Every benchmark checks what it measured. Replays compare each checkpoint with the pinned xterm reference and stop at the first mismatch. Each JSON report records the source revision and the host it ran on.

| Report | Command | What it measures | Recorded result |
| --- | --- | --- | --- |
| [First bytes](first-bytes.md) | `swift run -c release ThrushBench` | A prompt, cursor query and Up key through the core | 8-byte prompt p95 875 ns, cursor query p95 542 ns |
| [Headless replay](headless.md) | The same command | Sustained ASCII, recorded shell, Vim and Codex output, bounded queues and resize | 193 MiB/s at 80 × 24, against a 100 MiB/s target. Worst full-history resize p95 0.582 ms, against 8.333 ms |
| [Rendering](rendering.md) | `swift run -c release ThrushBench --render .build/demo/mac/Thrush.app` | Shader compile, first content, warm redraws, theme switches and idle frames in the packaged Mac app | Warm full grid p95 0.274 ms CPU and 0.102 ms GPU. Zero frames while idle or hidden |
| [Native input](rendering.md#native-input-and-echo-latency) | `swift run -c release ThrushBench --interactions .build/demo/mac/Thrush.app` | Composition, paste and keys from the native responder to the socket and back | Not yet recorded |
| [Connection](connection.md) | `swift run -c release ThrushBench --connection` | Attach, resume, takeover, reclaim, expiry, recovery and in-band replay over loopback | Foreground ready and replay to Up p95 0.872 ms |
| [Real PTY](pty.md) | `scripts/check-pty.sh --toy-box ../toy-box` | Numbered logs, reader comparisons and exit delivery against a disposable Toy Box server | A paced 1 MiB/s log arrives intact. Faster bursts expose the server's 1 MiB send guard, which Toy Box is fixing |
| [PTY recovery](pty-recovery.md) | `scripts/check-pty.sh --recovery --working-tree --toy-box ../toy-box` | Silent repair and exit order after a stalled reader, against a Toy Box candidate | Awaiting the server candidate |

Build the sample app with `scripts/build-demo.sh mac` before the rendering and input benchmarks. Run them from a logged-in, unlocked graphical session, since a locked display returns no presentation timestamps.

All results so far come from one contended M1 Max running macOS 27.2.1. They show correctness and headroom, not a timing baseline. Compare runs on the same machine and power state, and use five quiet passes before setting a timing gate. Physical iPhone timings need a device run.
