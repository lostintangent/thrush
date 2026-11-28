# Native input and echo latency

Build the Release app, then run the same input sequence through its native text responder and a fresh loopback socket.

```sh
scripts/build-app.sh proofs mac
bun Tests/ThrushProofs/peers/interaction-peer.ts .build/proofs/mac/Thrush.app .build/benchmarks/interactions.json

scripts/build-app.sh proofs simulator
bun Tests/ThrushProofs/peers/interaction-peer.ts --simulator "$udid" .build/proofs/simulator/Thrush.app .build/benchmarks/interactions-iphone.json
```

The peer expects 22 binary input frames. It checks one committed Japanese glyph after two marked-text updates, one bracketed paste and 20 printable keys. Each echo has a distinct terminal generation. The app also selects and copies a wide glyph across a soft wrap, reads a history row, and activates Latest.

Each key includes monotonic timestamps for the responder action, the WebSocket write and receipt of the corresponding echo. A matching Metal frame adds submission time. A drawable presentation callback adds visible-echo time on supported displays. The report publishes presentation percentiles only for runs in which all 20 keys have presentation timestamps. Compare visible echo against two display intervals using the interval measured on the same run. Environment fields record contention, thermal state, source revision and working-tree status.

The same report includes `anchoredReplay` for a scrolled 80 × 24 viewport with 1,000 history rows. Twenty replacements alternate between two pre-parsed snapshots whose numbered build steps shift by twelve rows. Each replacement must keep **Build step 512** at the top and **Build step 513** selected. The `milliseconds` samples and `p95Milliseconds` cover restoring the viewport and its native interaction state. Parsing, network latency and display timing are measured separately.

The [packaged Mac interaction report](interactions-mac.json) records a clean build of `2a3327e` on the contended M1 Max. Across 20 keys, p95 was 0.066 ms to the WebSocket write and 0.440 ms to receipt of the matching echo. All 20 echoes reached Metal submission. The locked display supplied no presentation times. Restoring the history reader and selection across 1,000 retained rows took 6.282 ms p95 over 20 replacements.
