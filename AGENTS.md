# Thrush

Thrush is a general-purpose Swift terminal for macOS and iOS apps. [docs/plan.md](docs/plan.md) is the source of truth for requirements, the ontology, contracts and budgets. When work changes a decision the plan records, update the plan in the same change.

## Principles

- The `ThrushCore` target uses only the Swift standard library. No Foundation, Darwin or third-party code.
- Add terminal behavior only when a named workflow or its recording needs it.
- Every new operation lands with its correctness checkpoint and its `ThrushBench` workload in the same change.
- ThrushCore is fast, correct and simple, and none of them is traded for another. The simplest, clearest design is the goal, and code that plain is also code people can learn from. Get speed from structure a reader would recognize, such as text runs, flat rows, a ring buffer and a table-driven parser, never from awkward or surprising code. Keep the few low-level techniques in the files [the emulator design](docs/emulator.md) names, explained where they live.
- A change that slows any ThrushBench workload doesn't land without the lead's agreement.
- Reference expectations come from outside Thrush. Never generate a fixture's expected output with Thrush itself.
- A pinned reference emulator is the conformance oracle and nothing more. Only the tooling that runs it, under `Fixtures/reference` and the scripts that drive it, names it. The comparison benchmark names the cores it measures. Code, tests and docs describe terminal behavior in their own terms, and code follows [the emulator design](docs/emulator.md) rather than another project's structure.
- Every noun earns its place. Use one word per concept across the API, code, docs and UI. Name a type with a public noun, a term [the emulator design](docs/emulator.md) defines, or a mechanism a reader already knows, such as a parser, renderer or scroll view. A new noun needs the lead's agreement.
- Build and test from the command line. There is no checked-in Xcode project.
- Write plans, specs, designs and reviews as Markdown that describes Thrush as it is today. History belongs in commit messages. Never use `.brief` files. Visuals such as SVG or PNG mockups live beside the Markdown that explains them.

## Naming

The product is Thrush. The folder, the GitHub repo and anything path-like are lowercase `thrush`.

## Shipping a change

- Work on `main` in small commits. Stage only the paths you own, because teammates share this working tree.
- Before committing, run the build, the tests and the core import check below.
- A change to what the iPhone view draws or how it lays out doesn't land until the full iPhone proof passes on its branch, unless the lead agrees a failure is already on `main`. Pushes skip that proof, so run it with `gh workflow run headless.yml --ref <branch>`.
- Commit messages use the imperative mood and end with the Copilot trailers.

## Commands

Run from the repository root. Use the full Xcode toolchain for the Swift Testing macros. This setting applies to the current shell.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
scripts/check-core.sh
scripts/check-swiftui-example.sh
scripts/check-websocket.sh
scripts/check-workflows.sh
swift run -c release ThrushBench
python3 Benchmarks/check-benchmark-report.py
```

The SwiftUI example in `examples/swiftui` builds the README integration using only the `Thrush` library product. The Release benchmark writes `.build/benchmarks/headless.json`. See [headless profiling and measurements](Benchmarks/headless.md) and [the shell and Vim fixture reference](Fixtures/reference/m2/README.md).

To measure ThrushCore against libghostty-vt and @xterm/headless on the same workloads, run `python3 Benchmarks/comparison/run.py`. It downloads and builds the pinned libghostty-vt with Zig on first use, checks that every core ends on the same screen, and writes `.build/benchmarks/comparison.json`. To see where ThrushCore spends its time on those workloads, run the Comparison profile workflow, which samples it on a hosted Mac with `Benchmarks/comparison/profile.py`. See [the comparison report](Benchmarks/comparison.md).

For real WebSocket and PTY checks, run `scripts/check-pty.sh`. Start the standalone server with `swift run ThrushServer`. The [PTY measurements](Benchmarks/pty.md) also cover slow readers and exit.

Some apps build for Mac with only Command Line Tools, so Thrush must build without Xcode. CI checks this, and you can run the same build in a fresh shell with `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --target Thrush --scratch-path .build/command-line-tools`. The separate scratch path keeps it from rebuilding the Xcode toolchain's products.

The WebSocket check uses Bun’s built-in WebSocket server and Apple’s URLSession WebSocket client.

`scripts/check-wasm.sh` builds the WebAssembly package with the swift.org Swift 6.4.2 toolchain and its Wasm SDK, then checks it against native ThrushCore and under Bun and Node. [Wasm/build.sh](Wasm/build.sh) lists what the build needs.

Build the Release sample app with `scripts/build-app.sh sample mac` or `simulator`, and the proofs app that mounts its window with `scripts/build-app.sh proofs mac` or `simulator`. See [running the sample app](docs/sample.md), [the proofs app](docs/proofs.md) and [measuring the packaged renderer](Benchmarks/rendering.md).
