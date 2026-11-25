# PTY recovery under backpressure

Run the in-band recovery and saturated-exit checks against the package’s standalone `ThrushServer`. For the packaged Mac check, use an empty output directory and a logged-in graphical session.

```sh
scripts/check-pty.sh --recovery
python3 -B scripts/live-workflow/launch.py --platform mac --workflow recovery \
  --bash /opt/homebrew/bin/bash --output .build/native-pty-recovery
```

The headless check writes `.build/benchmarks/pty-recovery.json`. It suspends the receiving process during the burst, requires an in-band replay while the shell is silent and checks all 24 rows against an independent reference. It then verifies live input and the final screen at shell exit. Use `--endpoint` to run against another compatible disposable loopback server. The numbered-log and reader checks have separate entry points. [Server and client commands](pty.md)

## Seen by a suspended reader

The server stops forwarding live output when a WebSocket has 256 frames pending or the next write would take queued live bytes above 1 MiB. It continues applying every PTY byte to its own terminal. Once pending output drains, the active socket receives `ready(resumed: true)` and a binary replay. The replay restores the screen and up to 1,000 normal history rows. A client can continue from the repaired screen even if older numbered lines have fallen outside the history window.

On a shared M1 Max running macOS 27.2.1, the suspended Swift reader received 801,792 of the 8,388,608 numbered bytes. It sent a nonce before reading the backlog. With PTY echo disabled, the producer acknowledged the nonce on disk and remained silent. The same socket then delivered a 65,513-byte replay. All 24 rows matched the independent oracle through marker 131,072. After recovery the shell echoed a second nonce and exited. Thrush received and applied 867,353 bytes. The test used a clean Release build at `6b33bf2`. [Recovery report](pty-recovery.json)

## Final output and natural exit

A distinct probe waits for the actual shell PID to disappear before letting its suspended reader run. The client verifies the final screen from binary frames delivered before the exit control, observes the WebSocket close, then attaches with the same client ID and checks the replacement PID.

| Reader | Live bytes received / expected | Final output | WebSocket outcome |
| --- | ---: | --- | --- |
| Continuous | 8,388,627 / 8,388,627 | Shell’s final marker in the live stream | Exit, close 1000, fresh PID |
| Suspended | 801,792 / 8,388,627 | 65,468-byte replay restored the final marker and every expected row | Exit, close 1000, fresh PID |

The saturated probe held the reader for one second after confirmed shell death. The report also records whether the socket remained open and whether a ping received a response during the three-second observation window. [Exit probes](pty-recovery.json)
