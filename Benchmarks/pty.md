# Disposable Toy Box PTY

Run the macOS headless check from the Thrush checkout. It builds the Release Swift client, starts a private Toy Box server, runs four numbered logs over real WebSockets and PTYs, and checks the server's 30-second orphan timeout. The JSON report is written to `.build/benchmarks/pty-smoke.json`. The check removes its temporary server data on exit.

```sh
scripts/check-pty.sh --toy-box ../toy-box
```

For a Mac demo, iOS Simulator or integration client, launch the same server in its own terminal. Supply an empty data directory and a free port. Port zero asks macOS to choose one. Use the printed loopback URL as the client endpoint.

```sh
pty_data=$(mktemp -d)
scripts/serve-pty.py --toy-box ../toy-box --port 3129 --data-dir "$pty_data"
```

The launcher builds the pinned `b9d0eca3c5f4e9036e58327ba633eff52474bb92` source and locked dependencies with Bun, then caches that production build under `.build/pty-server`. The first build needs Bun and access to the locked packages or a populated Bun cache. The server binds to `127.0.0.1`. PTYs start in `work/` with a private `home/`, including the Toy Box database, and `tmp/`. The server receives a minimal environment. New PTYs run `/bin/zsh` by default. Pass `--shell /bin/sh` to choose another executable. Control-C stops the server. The supplied data directory remains available for inspection.

## What the smoke measures

The smoke launcher identifies itself with a random token printed by its real shell. The Swift client verifies that token on its grid before sending a command. A Python producer runs on the PTY, confirms its 80 × 24 window and emits fixed 64-byte numbered records. An independent oracle checks payload bytes, order and complete markers. Binary frames applied through the first live end fence make up the received and applied totals. Those counts include the initial shell output and fences.

The paced case targets 1 MiB/s. Three further cases use the same unpaced 8 MiB producer. One reads freely. One caps cumulative applied bytes per elapsed second at one quarter of the Mac's reference 80 × 24 bulk ASCII parser rate. The third suspends the Swift process before the producer starts and resumes it one second after the final write. The producer holds its PTY open until a new attachment receives the server's serialized screen and acknowledges it. The host compares all 24 visible rows against the independent expected screen before and after reconnect. A final marker must remain visible at shell exit.

The producer timestamps each completed 8 KiB write. The Swift client timestamps each binary frame immediately after applying it. Both clocks use macOS system uptime. The peak byte gap is the largest observed cumulative difference between PTY payload written and live payload applied. It spans the server, transport and client and includes permanently skipped bytes. The adapter pulls one binary frame at a time. The first-to-last application rate covers the received portion of the log. Command-to-exit time also includes shell startup for the producer, replay and acknowledgement. [Reference parser rates](headless.json) · [Toy Box send guard](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/src/features/terminal/server/runtime.ts)

## Mac result

On November 24, 2026, an Apple M1 Max running macOS 27.2.1 and Bun 1.4.6 produced the following results. The Swift client ran from the dirty development worktree based on `43aa100e774cc43025d594f75e2b3b9bea527ac4` during implementation of this check. The production server was built from the exact Toy Box revision above. [Captured report](pty-smoke.json)

Each burst generated 131,072 numbered markers totaling 8,388,608 bytes. The paced run generated 8,192 markers totaling 524,288 bytes. The limited reader used a 48.255 MiB/s cap, one quarter of the 193.018 MiB/s reference parser measurement. Its measured application rate over the socket was 10.913 MiB/s. The limited reader ran below its nominal cap. Scheduling, transport and other work on the Mac affect these measurements, so the two burst runs alone cannot isolate the effect of throttling.

| Reader | Producer / applied MiB/s | Socket bytes received / applied | Intact markers | Payload bytes missing | First missing marker | Peak byte gap | Last visible marker, live → replay | Command to exit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Paced | 0.995 / 1.010 | 524,506 / 524,506 | 8,192 | 0 | None | 13,312 | 8,192 → 8,192 | 1,735 ms |
| Live burst | 16.038 / 10.919 | 7,891,160 / 7,891,160 | 123,296 | 497,664 | 76,369 | 3,938,304 | 131,072 → 131,072 | 1,978 ms |
| Limited burst | 23.913 / 10.913 | 5,747,934 / 5,747,934 | 89,808 | 2,640,896 | 57,089 | 4,784,128 | 119,360 → 131,072 | 1,237 ms |
| Suspended burst | 39.803 / 15.984 | 1,596,642 / 1,596,642 | 24,944 | 6,792,192 | 24,945 | 8,388,608 | 24,944 → 131,072 | 1,479 ms |

The adapter applied every received byte. Under burst load, the first missing markers occurred upstream of the adapter, including on the continuously reading client. Toy Box skips a live write when its socket buffer holds at least 1 MiB. The peak byte gap in the table includes kernel buffers, serialization and permanent loss. The largest single application frame was 2,048 bytes.

The continuously reading client reached marker 131,072 and all its final visible rows matched despite the missing interior output. The limited client stopped at visible marker 119,360 and the suspended client stopped at 24,944. Detach and reattach restored marker 131,072 and all 24 expected visible rows in each burst. Replay recovers the server's retained screen and bounded history. The server retains up to 1,000 normal history rows. Older missing log lines fall outside that retention window.

The same disposable server passed fresh attach, resize confirmed by `stty size`, foreground return with the original shell PID and environment, takeover with displaced-owner suppression, explicit close observed through shell-process exit, real orphan expiry measured at 30.069 seconds, and a final output marker visible at exit. GUI presentation, three interactive workflows, and physical iPhone behavior remain separate acceptance checks.

## Count-only readers and exit under backpressure

```sh
scripts/check-pty.sh --readers --toy-box ../toy-box
```

This follow-up uses the same pinned production Toy Box server and Release Swift client as the four-profile check above. It compares a Bun WebSocket counting binary frame lengths, an ephemeral URLSession WebSocket doing the same, and `TerminalConnection` applying every binary frame to an 80 × 24 terminal. The Thrush run reads its byte counters only at exit. Both discard readers release each frame immediately.

Each PTY produces the same 131,072 numbered records in batches of 128. Binary data consists of exactly 8,388,608 payload bytes. The test gates the producer after fresh ready and omits prompts, shell echo and in-band fences. A JSON exit ends each comparison after a one-second drain allowance. One producer uses cumulative deadlines targeting 16 MiB/s. The other writes each newly formatted batch immediately, as in the original unpaced smoke. Three rounds rotate the reader order. The recorded peak is the most data accepted by PTY writes in any 50 ms window.

Two separate exit checks let a real `/bin/sh` write a 19-byte final marker and exit immediately after the burst. An independent process verifies that the shell's final write succeeded and its PID disappeared. The reader gets three seconds to drain after shell death or after resuming from suspension. It then checks for a nonce-matched WebSocket pong, reconnects with the same client ID and checks whether the server resumes or starts a new shell. Each wait has a deadline.

### Continuous readers

All 18 comparisons received the full 8 MiB. Thrush applied every received byte in its six runs. Eight of the nine paced runs produced 15.93 to 16.00 MiB/s. The third paced Thrush run produced 8.01 MiB/s. Its first two runs both reached 16.00 MiB/s. The Mac ran macOS 27.2.1 and Bun 1.4.6. The Swift client ran from a dirty development checkout based on `730c5e277f3036ad7469a35442cc7810cec9c862`, against unmodified Toy Box `b9d0eca3c5f4e9036e58327ba633eff52474bb92`. [Captured measurements](pty-readers.json)

| Reader | Workload | Producer MiB/s, runs 1–3 | Peak 50 ms MiB/s, runs 1–3 | Missing bytes, runs 1–3 |
| --- | --- | --- | --- | --- |
| Bun discard | 16 MiB/s target | 15.99, 15.99, 15.93 | 24.22, 16.88, 17.97 | 0, 0, 0 |
| URLSession discard | 16 MiB/s target | 16.00, 15.99, 16.00 | 18.44, 19.53, 17.03 | 0, 0, 0 |
| Thrush apply | 16 MiB/s target | 16.00, 16.00, 8.01 | 23.12, 17.66, 19.53 | 0, 0, 0 |
| Bun discard | Unpaced | 18.73, 24.03, 19.32 | 23.12, 27.03, 28.28 | 0, 0, 0 |
| URLSession discard | Unpaced | 24.87, 22.63, 21.53 | 27.50, 24.84, 26.56 | 0, 0, 0 |
| Thrush apply | Unpaced | 14.69, 23.00, 15.41 | 22.97, 26.25, 20.94 | 0, 0, 0 |

The earlier instrumented live run lost 497,664 bytes at an average producer rate of 16.04 MiB/s. These six uninstrumented URLSession-discard and Thrush comparisons on the unpaced producer showed zero loss. All three unpaced Bun runs also showed zero loss. Burst timing, machine load and the earlier client's per-frame capture differed. These trials do not isolate a parser cost as the cause of the earlier drop. Toy Box's conditional live send explains how data can be omitted when a peer falls behind. [Production send path](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/src/features/terminal/server/runtime.ts)

### Shell exit under backpressure

| Bun reader at exit | Expected / received binary bytes | Final shell marker | Exit control | Pong after shell death | Same client ID on reconnect |
| --- | ---: | --- | --- | --- | --- |
| Continuous | 8,388,627 / 8,388,627 | Received | Received | Received | Fresh PTY |
| Suspended | 8,388,627 / 1,597,440 | Missing | Missing | Received | Fresh PTY |

In the suspended case the shell wrote its final marker and died before the reader resumed. The reader remained connected, drained what reached it, and received the reply to its own ping. The server had already deleted the shell and its replay when the same client ID reattached. Toy Box sends the exit control through the same 1 MiB guard as output. A healthy socket can therefore outlive a shell without telling the host it exited. [Exit and send implementation](https://github.com/lostintangent/toy-box/blob/b9d0eca3c5f4e9036e58327ba633eff52474bb92/src/features/terminal/server/runtime.ts)
