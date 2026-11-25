# Real PTY recovery under backpressure

The candidate restored the terminal’s visible screen on the existing connection after a reader fell behind. In the suspended 8 MiB log run, the reader missed 106,128 of 131,072 original markers, then recovered all 24 expected rows through marker 131,072 before reconnecting. A separate native Mac run recovered a silent screen and accepted fresh input in the same pane.

All five reports use Toy Box base `b9d0eca3c5f4e9036e58327ba633eff52474bb92` and working-tree SHA-256 `9b64ec1ce40bf269355ec124fa4707daab6efa811eaf2efc8dfd2ec60efadc9f`, with Bun 1.4.6 on macOS 27.2.1. The numbered-log and reader reports record a development tree based on `fafa231`. The focused checks ran on clean `a6fa430`, and the native Mac run used clean `f8c58c4`. The combined JSON retains the original report objects and their source-file hashes. The earlier pinned-server runs remain available for comparison. [Candidate run data](pty-candidate.json) · [Historical pin](pty.md)

## Numbered logs

When a socket has at least 1 MiB buffered, the candidate can omit live output. Once the socket drains to zero, it sends `ready(resumed: true)` followed by a serialized screen on the same attachment. Thrush replaces its screen and parser state, then applies subsequent live frames in order. The serialization covers the viewport and up to 1,000 normal history rows. Skipped lines older than that history remain missing from the client’s log.

| Reader | Producer / live apply MiB/s | Intact / expected markers | Original payload bytes skipped | In-band repairs / serialized bytes | Peak written minus applied bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| Paced | 0.994 / 1.011 | 8,192 / 8,192 | 0 | 0 / 0 | 8,192 |
| Direct burst | 18.518 / 11.340 | 123,568 / 131,072 | 480,256 | 1 / 65,472 | 3,351,552 |
| Rate-limited burst | 20.735 / 9.242 | 87,584 / 131,072 | 2,783,232 | 2 / 130,902 | 4,872,192 |
| Suspended burst | 26.903 / 13.465 | 24,944 / 131,072 | 6,792,192 | 1 / 65,430 | 8,388,608 |

The limited reader’s nominal cap was 48.255 MiB/s. Marker counts and live apply rates exclude serialization bytes. The peak gap compares completed PTY writes with original payload bytes applied and includes permanently skipped data. In each run Thrush applied every binary byte it received, and all 24 rows matched the independent expected screen both before and after an explicit detach and reattach. The `smoke` report records each run separately.

All 18 reader comparisons delivered every byte of their 8 MiB payloads without a repair. Bun discard, URLSession discard and Thrush apply each completed three paced and three unpaced runs. Paced producers reached 15.604–15.998 MiB/s, and unpaced producers reached 18.006–23.864 MiB/s. The `readers` report gives actual rates and 50 ms peaks for each run. Per-frame tracing and machine scheduling differed from the numbered-log checks. [Measurements](pty-candidate.json)

## Silent recovery and native input

In the focused `recovery` run, the Swift reader resumed after the producer finished writing. It sent a nonce before reading the backlog. With PTY echo disabled, the producer acknowledged that nonce on disk and remained silent. Thrush received 1,597,440 original numbered bytes and a 65,472-byte replacement screen, restored every expected row on the original socket, and displayed the echo of a second nonce. All 1,662,960 received bytes were applied.

For `nativeMac`, the packaged Mac app stayed running while the process reading its upstream socket was suspended for 2.545 s. The server restored the build summary with a 179-byte replay on the original attachment. The rendered grid showed “131072 compilation updates processed” and “Ready for input”. A subsequent command produced a 37-byte echo in the same pane. The three checkpoints record matching accepted and rendered generations. This run captured no presentation timestamps. [Measurements and capture hashes](pty-candidate.json)

## Exit when a reader stalls

The focused exit check independently observed the real shell PID die before resuming the suspended reader. The socket delivered 1,597,440 live bytes, then a 65,427-byte replay. A fresh terminal reconstructed the final 22 numbered rows, the shell’s final marker and the blank cursor row from the bytes preceding the exit control. The server then closed with code 1000. A subsequent attachment with the same client ID started a fresh shell.

The `stalledExit` runs kept the complete reader process suspended for longer intervals. Each duration below starts at independent confirmation of shell death and ends when the process resumes.

| Reader and post-death hold | Observed outcome |
| --- | --- |
| Raw WebSocket, 4.505 s | Received the final marker in a 65,427-byte replay, then exit and close 1000. Same-ID reattachment started a fresh shell. |
| Raw WebSocket, 7.010 s and 8.502 s | Each reader got 551,936 live bytes and closed abnormally with code 1006. Neither received replay, final marker or exit. Each reattachment started a fresh shell. |
| URLSession with `TerminalConnection`, 8.504 s | The adapter observed `reconnecting` followed by fresh ready and set `replacedPreviousShell`. It discarded the input held for the old shell. The replacement PID received only the 41-byte command sent after fresh ready. |

The observed boundary depends on transport buffering, output rate and peer scheduling. These durations describe trials on this Mac. A reader that makes no progress can lose the shell’s last screen and exit control when its socket closes. [Raw socket and native adapter reports](pty-candidate.json)

## Reproduce

Run from the Thrush checkout with the candidate Toy Box working tree at the supplied path. Each command starts a disposable loopback server, records the source fingerprint and uses a private home. The default headless command without `--working-tree` reproduces the historical pin.

```sh
scripts/check-pty.sh --recovery --working-tree --toy-box ../toy-box
scripts/check-pty.sh --readers --working-tree --toy-box ../toy-box
scripts/check-pty.sh --working-tree --toy-box ../toy-box
python3 scripts/live-workflow/launch.py --platform mac --workflow recovery --working-tree \
  --toy-box ../toy-box --bash /opt/homebrew/bin/bash --output .build/native-pty-recovery
```

The headless reports go to `.build/benchmarks/pty-recovery-candidate.json`, `pty-readers-candidate.json` and `pty-smoke-candidate.json`. The native launcher requires an empty output directory and a logged-in graphical session.
