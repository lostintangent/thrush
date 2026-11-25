# Real PTY recovery under backpressure

Run the focused acceptance check against the Toy Box checkout containing the in-band recovery implementation.

```sh
scripts/check-pty.sh --recovery --working-tree --toy-box ../toy-box
```

The launcher snapshots the selected Toy Box sources and records their fingerprint. The check uses that production build, a private home, and three fresh 80 × 24 PTYs. It writes `.build/benchmarks/pty-recovery-candidate.json`.

The silent case suspends the entire Swift reader before the producer writes 131,072 numbered rows. After writing 8 MiB, the producer waits for input with PTY echo disabled. The client resumes and sends a nonce before it reads the accumulated output. The producer acknowledges the nonce on disk and keeps the terminal silent. The adapter must then emit `resynchronized` on the same attachment and restore all 24 expected rows, including marker 131,072. A second input produces a visible nonce echo before the shell exits. Live-stream counts exclude the serialized replacement screen.

The exit cases use a continuously reading Bun client and a suspended one. A real shell writes its final marker and exits while the suspended reader is still stopped. The test independently observes the shell PID disappear. The saturated probe retains the last complete serialization and any subsequent live bytes that precede the exit control. Feeding those bytes to a fresh terminal must reproduce the last 22 numbered rows, the shell’s final marker and the blank cursor row. The test also verifies exit arrived before server close code 1000 and that reattaching with the same client ID starts a fresh shell.

The broader smoke and three-reader comparisons accept the same `--working-tree` arguments. Their candidate reports distinguish serialized bytes from live bytes and use `pty-smoke-candidate.json` and `pty-readers-candidate.json`. Omitting `--working-tree` runs the pinned-server profiles. [Pinned measurements](pty.md)
