# Transport measurements

These workloads time a session's transport, which moves bytes between the session and its shell.

## WebSocket transport

Run `swift run -c release ThrushBench --websocket` from the repository root with the full Xcode toolchain and Bun on the path. The command builds the matching Release loopback client, prints p50 and p95 in milliseconds, and writes `.build/benchmarks/websocket.json`. Use `--output PATH` to retain another run.

The workload starts a Bun WebSocket peer on the Mac’s loopback interface. The first six attachments cover a fresh shell, a brief detach and foreground return, takeover by a second WebSocket client, user-initiated reclaim, orphan expiry and a fresh shell after explicit close. This shell sends its last two output frames before exit. The initial 16 × 3 grid makes a single row of history observable on resume. The first client sends one 18 × 3 resize and the foreground attachment returns to 16 × 3. During reclaim the session coalesces two requests into a single 17 × 3 resize after replay. Both sides check the exchange in every pass.

Five more attachments exercise automatic recovery. The checker fails five socket creations and advances the WebSocket transport through delays of 250, 500, 1,000, 2,000, 4,000 and 4,000 ms on an injected clock. The peer observes the resumed replay followed by three held inputs in order, including an application-mode arrow and a bracketed paste. Subsequent phases check the 250 ms reset, both queue limits, the session discarding 64 KiB of held input when it adopts a replacement shell, a new session after exit, and background cancellation of a pending retry with 256 keys held. The final foreground resume must receive only newly typed input. An active send that fails on the lost URLSession task never reaches a later socket.

A twelfth attachment exercises in-band replay on an active socket. The old screen ends partway through an OSC string with application cursor keys enabled. After a second ready announces the replay, the checker requests a resize and sends Up. The peer receives the old-mode Up before releasing the snapshot. In one turn it sends the serialized replacement and the next live byte. The checker observes one replay event with the new history, visible rows, cursor and modes, followed by one live output event. The peer checks the deferred resize, restored Up and bracketed paste bytes, then sends final output, exit and close code 1000. The reported “In-band replay to deferred resize” interval starts when the peer releases the snapshot and ends when it receives the deferred resize. The final two attachments check rejection of a fresh ready on an active socket and a duplicate ready in place of a replay body.

The peer runs the same script as `scripts/check-loopback.sh`. For each replay the peer sends a fixed VT byte sequence. The preserved normal screen contains one history row and three visible rows. The alternate screen and application cursor mode survive takeover, including output that appeared before the new owner connected. [Recorded replay bytes](../scripts/lifecycle-peer.ts)

The first complete exchange is a warmup. Five measured passes each launch a fresh peer and client. A single monotonic peer clock, `Bun.nanoseconds()`, brackets each named interval. For example, “Foreground ready and replay to Up” begins immediately before queuing ready, serialized replay and live output. It ends when the peer handles the client’s binary Up key. These intervals include socket I/O, scheduling, session work and the client’s screen checks. The detach and exit intervals end at the peer’s WebSocket close callback. WebSocket setup, process startup and compilation fall outside the intervals.

The peer advances an independent virtual clock to test the 30-second orphan deadline immediately before and at expiry. The post-expiry measurement begins when the fresh ready frame is sent. The reclaimed replay interval begins when the peer releases the held replay frame. The automatic recovery interval starts at the resumed ready response, after the injected backoff. These intervals exclude the time spent waiting at those gates.

The JSON records each interval’s five samples in nanoseconds, nearest-rank p50 and p95, the peer script’s SHA-256 and the machine environment. Five samples make p95 the slowest measured sample. The report describes scripted, headless macOS loopback. Presentation and physical iPhone measurements have separate workloads. CI checks wire and screen correctness independently of elapsed time.

### Recorded run

The M1 Max completed five measured passes on `559d507`. The one-minute load average was 91.70 across ten active cores, with thermal state fair. The table gives four peer-observed intervals from the run. The JSON includes all 22 intervals and their individual samples. [Raw measurements](websocket.json)

| Interval | p50 | p95 |
| --- | ---: | ---: |
| Foreground ready and replay to Up | 0.799 ms | 0.872 ms |
| Recovery ready and replay to held Up | 0.454 ms | 0.905 ms |
| In-band replay to deferred resize | 0.291 ms | 0.345 ms |
| Final ready, output and exit to socket close | 0.680 ms | 0.941 ms |

## App transport

Run `swift run -c release ThrushBench --app-transport` to time the session with an app-supplied `TerminalTransport` from its first read through EOF. The checker verifies the first-bytes fixture’s final rows, reply bytes and received/applied counts. One warmup and five measured passes produce `.build/benchmarks/app-transport.json`.

## Measure a replay

The serializer workload measures the time to encode each recorded checkpoint. A fresh terminal consumes the bytes and checks every visible and historical cell against the recording. The independent reference then receives the same bytes and the following program output. The fixture checks count the two fixed-grid resize losses described in the [terminal protocol](../docs/protocol.md#replay).

```sh
bun install --cwd Fixtures/reference --frozen-lockfile
swift build -c release --product ThrushBench
bun Fixtures/reference/check-serialization.mjs "$(swift build -c release --show-bin-path)/ThrushBench"
```

The command prints the checkpoint count, total encoded bytes and median encoding time for each recording.
