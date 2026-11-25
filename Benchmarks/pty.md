# Real PTY checks

Run the headless checks from the Thrush checkout on macOS with the full Xcode toolchain. Each command builds the Release Swift client, starts the package’s `ThrushServer` on loopback with a private home and work directory, and removes its server data on exit. The reader and recovery checks also use Bun for the independent WebSocket reader.

```sh
scripts/check-pty.sh
scripts/check-pty.sh --readers
scripts/check-pty.sh --recovery
```

The reports are `.build/benchmarks/pty-smoke.json`, `pty-readers.json` and `pty-recovery.json` in the same directory. The smoke check exercises four numbered logs and the 30-second orphan timeout. The reader comparison measures three clients against the same producer. The recovery check requires an actual interrupted stream, in-band screen repair during silence, successful input and a complete final screen before exit. [Recovery procedure](pty-recovery.md)

To use the server with a demo app or a separate client, supply an empty data directory and a loopback port. Port zero selects a free port and prints the origin. Control-C stops the server and leaves its data directory available for inspection.

```sh
pty_data=$(mktemp -d)
swift run -c release ThrushServer --port 3129 --data-dir "$pty_data" --shell /bin/sh
```

To check a different implementation, point any of the three commands at a disposable loopback origin with `--endpoint http://127.0.0.1:3129`. The server and client must share the same Mac filesystem and process namespace, and the configured shell must accept a POSIX `exec` command. The check requests fresh UUID sessions and enters a private fixture shell through the original WebSocket. Reader measurements begin after a nonce-delimited setup line has been completely received. Reports for supplied endpoints go under `.build/benchmarks/external/` and identify the endpoint. The harness leaves that server running. [Independent endpoint compatibility result](pty-compatibility.json)

## Numbered logs

A real shell prints a fresh nonce before starting the producer on an 80 × 24 PTY. It writes 64-byte numbered lines and waits for a second attachment to acknowledge its final screen. An independent oracle checks the payload, order and all 24 expected rows. The adapter counts live output and in-band screen repairs separately.

On an M1 Max running macOS 27.2.1, the standalone server and client restored the expected visible rows before and after reconnect in all four cases. Thrush applied every received byte. The measurements used a clean Release build at `6b33bf2`. [Smoke report](pty-smoke.json)

| Reader | Intact / expected markers | Missing live bytes | Screen repairs | Producer / live apply (MiB/s) | Peak written minus applied (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Paced at 1 MiB/s | 8,192 / 8,192 | 0 | 0 | 0.99 / 1.01 | 8,192 |
| Continuous burst | 93,376 / 131,072 | 2,412,544 | 6 | 11.99 / 8.25 | 2,664,448 |
| Rate-limited burst | 55,024 / 131,072 | 4,867,072 | 4 | 36.66 / 10.55 | 5,974,016 |
| Suspended burst | 12,560 / 131,072 | 7,584,768 | 1 | 19.36 / 13.61 | 8,388,608 |

The three bursts use the same 8 MiB payload. The rate-limited reader caps its pull rate at 111.316 MiB/s, one quarter of the measured 80 × 24 parser throughput. The suspended process resumes one second after the producer finishes. The peak byte gap compares completed PTY writes with original payload bytes applied using the Mac’s uptime clock. It includes kernel buffering, server and client work, and permanently skipped output. The live apply rate covers the received payload between its first and last applied frames. [Parser reference](headless.json)

## Reader comparison

Three clients each run the same 8 MiB producer six times, with the order rotated. Bun and a bare URLSession count incoming frame lengths. The third client uses the session’s `TerminalWorker` to parse and apply each frame. The producer starts after the reader is ready and exits after a one-second drain interval.

| Client | Paced runs fully received | Unpaced runs fully received | Missing live bytes in each unpaced run |
| --- | ---: | ---: | ---: |
| Bun | 3 / 3 | 2 / 3 | 0 · 0 · 226,304 |
| URLSession | 3 / 3 | 0 / 3 | 217,088 · 402,432 · 238,592 |
| Thrush | 3 / 3 | 0 / 3 | 606,208 · 939,008 · 402,432 |

The unpaced producers ranged from 36.90 to 44.28 MiB/s. The report separates original payload bytes from screen repairs and includes 50 ms producer peaks for each run. [Reader report](pty-readers.json)
