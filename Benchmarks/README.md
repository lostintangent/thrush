# Benchmarks

Every benchmark checks what it measured. Recording benchmarks compare each checkpoint with the pinned reference emulator and stop at the first mismatch. Each JSON report records the source revision and the machine it ran on.

| Report | Command | What it measures |
| --- | --- | --- |
| [Comparison](comparison.md) | `python3 Benchmarks/comparison/run.py` | Nine 1 MiB recorded and synthetic workloads through ThrushCore, libghostty-vt 1.0.2 and @xterm/headless 6.0.0 at two grids, with screen checks and allocations, plus a profile from a hosted Mac |
| [Headless recordings](headless.md) | `swift run -c release ThrushBench` | Sustained ASCII, recorded shell, Vim and Codex output, bounded queues and resize |
| [Mac rendering](rendering.md#mac-measurement) | `.build/proofs/mac/Thrush.app/Contents/MacOS/ThrushProofs --benchmark .build/benchmarks/render.json` | Shader compile, first content, warm redraws, theme switches and idle frames in the packaged Mac app |
| [iPhone simulator rendering](rendering.md#iphone-simulator-measurement) | `Tests/ThrushProofs/benchmark-simulator.sh "$udid" .build/proofs/simulator/Thrush.app .build/benchmarks/render-simulator.json` | The same Release workload and an actual UIKit background transition |
| [Native input](rendering.md#native-input-and-echo-latency) | `bun Tests/ThrushProofs/peers/interaction-peer.ts .build/proofs/mac/Thrush.app .build/benchmarks/interactions.json` | Composition, paste and keys from the native responder to the socket and back |
| [WebSocket lifecycle](transport.md) | `swift run -c release ThrushWebSocketCheck --benchmark` | Attach, resume, takeover, reclaim, expiry, recovery and in-band replay over loopback |
| [Real PTY](pty.md) | `scripts/check-pty.sh` | Numbered logs through the standalone server, and exit under pressure |
| [Native PTY workflows](live-workflows.md) | `python3 Tests/ThrushProofs/launch.py --help` | Native Shell, Vim, Codex, lifecycle and recovery over real PTYs |

Build the proofs app with `scripts/build-app.sh proofs mac` before the rendering and input benchmarks. Run them from a logged-in, unlocked graphical session, since a locked display returns no presentation timestamps.
