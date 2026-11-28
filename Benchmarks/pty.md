# Real PTY checks

Run the headless check from the Thrush checkout on macOS with the full Xcode toolchain. It builds the Release Swift client, starts the package’s `ThrushServer` on loopback with a private home and work directory, runs three numbered logs and a resize check, and removes its server data on exit. The report is `.build/benchmarks/pty-smoke.json`.

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

On a shared M1 Max running macOS 27.2.1 with a load average near 5, the two acknowledged runs showed the expected rows live and after reattach, and the suspended run restored them with its replay before exit. Thrush applied every received byte. The measurements used a clean Release build at `3a89a8d`. [Smoke report](pty-smoke.json)

| Reader | Intact / expected markers | Missing live bytes | Screen repairs | Producer / live apply (MiB/s) | Peak written minus applied (bytes) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Paced at 1 MiB/s | 8,192 / 8,192 | 0 | 0 | 1.00 / 1.01 | 8,192 |
| Continuous burst | 116,656 / 131,072 | 922,624 | 4 | 40.53 / 30.91 | 2,314,240 |
| Suspended burst | 12,544 / 131,072 | 7,585,792 | 1 | 77.88 / 21.99 | 8,388,608 |

The two bursts use the same 8 MiB payload. The suspended process resumes one second after the shell exits. The peak byte gap compares completed PTY writes with original payload bytes applied using the Mac’s uptime clock. It includes kernel buffering, server and client work, and permanently skipped output. The live apply rate covers the received payload between its first and last applied frames.

## Resizes

A program in the shell paints every row of the alternate screen when the check asks and ignores SIGWINCH, as many simple programs do. Each resize goes out while the client still holds the latest frame unread, so the frame was written for the old grid. The grid shrinks from 80 × 24 to 40 × 12, grows to 60 × 30 and then 100 × 20 before the first answer, and shrinks to 80 × 10. The live terminal must keep its grid until the server's answer arrives, and after each step a fresh attachment's replay must equal the live screen. A raw socket that marks no resize must see the shell take the grid and get no answer, as a client from before resize answers expects.
