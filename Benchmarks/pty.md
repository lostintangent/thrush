# Real PTY checks

Run the headless check from the Thrush checkout on macOS with the full Xcode toolchain. It builds the Release Swift client, starts the package’s `ThrushServer` on loopback with a private home and work directory, runs four numbered logs and removes its server data on exit. The report is `.build/benchmarks/pty-smoke.json`.

```sh
scripts/check-pty.sh
```

To use the server with the sample app or a separate client, supply an empty data directory and a loopback port. Port zero selects a free port and prints the origin. Control-C stops the server and leaves its data directory available for inspection.

```sh
pty_data=$(mktemp -d)
swift run -c release ThrushServer --port 3129 --data-dir "$pty_data" --shell /bin/sh
```

## Numbered logs

A real shell prints a fresh nonce before starting the producer on an 80 × 24 PTY. It writes 64-byte numbered lines and waits for a second attachment to acknowledge its final screen. In the suspended run, the shell exits instead while the client is stopped. The server must then replay the final screen before exit, and the same ID must start a fresh shell. An independent oracle checks the payload, order and all 24 expected rows. The session counts live output and in-band replays separately.

On an M1 Max running macOS 27.2.1, the standalone server and client restored the expected visible rows before and after reconnect in all four cases. Thrush applied every received byte. The measurements used a clean Release build at `6b33bf2`. [Smoke report](pty-smoke.json)

| Reader | Intact / expected markers | Missing live bytes | Screen repairs | Producer / live apply (MiB/s) | Peak written minus applied (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Paced at 1 MiB/s | 8,192 / 8,192 | 0 | 0 | 0.99 / 1.01 | 8,192 |
| Continuous burst | 93,376 / 131,072 | 2,412,544 | 6 | 11.99 / 8.25 | 2,664,448 |
| Rate-limited burst | 55,024 / 131,072 | 4,867,072 | 4 | 36.66 / 10.55 | 5,974,016 |
| Suspended burst | 12,560 / 131,072 | 7,584,768 | 1 | 19.36 / 13.61 | 8,388,608 |

The three bursts use the same 8 MiB payload. The rate-limited reader caps its pull rate at 111.316 MiB/s, one quarter of the 80 × 24 parser throughput archived when the check ran. The suspended process resumes one second after the shell exits. The peak byte gap compares completed PTY writes with original payload bytes applied using the Mac’s uptime clock. It includes kernel buffering, server and client work, and permanently skipped output. The live apply rate covers the received payload between its first and last applied frames. [Parser reference at 75860e3](https://github.com/lostintangent/thrush/blob/bab33fda31fca69f965bbfc1b37507e7b28e17e8/Benchmarks/headless.json)

