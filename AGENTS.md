# Thrush

Thrush is a first-party Swift terminal emulator for macOS and iOS. [docs/plan.md](docs/plan.md) is the source of truth for requirements, the ontology, contracts, budgets and milestones. When work changes a decision the plan records, update the plan in the same change.

## Principles

- The `ThrushCore` target uses only the Swift standard library. No Foundation, Darwin or third-party code.
- Add terminal behavior only when a named workflow or its recorded replay needs it.
- Every new operation lands with its correctness checkpoint and its `ThrushBench` workload in the same change.
- Reference expectations come from outside Thrush. Never generate a fixture's expected output with Thrush itself.
- Build and test from the command line. There is no checked-in Xcode project.
- Write plans, specs, designs and reviews as Markdown. Never use `.brief` files. Visuals such as SVG or PNG mockups live beside the Markdown that explains them.

## Naming

The product is Thrush. The folder, the GitHub repo and anything path-like are lowercase `thrush`.

## Shipping a change

- Work on `main` in small commits. Stage only the paths you own, because teammates share this working tree.
- Before committing, run the build, the tests and the core import check below.
- Commit messages use the imperative mood and end with the Copilot trailers.

## Commands

Run from the repository root. Use the full Xcode toolchain for Swift Testing macros and the SwiftSyntax modules in the core import check. This setting applies to the current shell.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
swift test
scripts/check-core.sh
scripts/check-app-consumer.sh
scripts/check-loopback.sh
scripts/check-workflows.sh
swift run -c release ThrushBench
python3 scripts/check-benchmark-report.py
```

The separate app consumer builds the README integration using only the `Thrush` library product. The Release benchmark writes `.build/benchmarks/first-bytes.json` and `.build/benchmarks/headless.json`. See [the first-bytes procedure](Benchmarks/first-bytes.md), [headless profiling and measurements](Benchmarks/headless.md) and [the shell and Vim fixture reference](Fixtures/reference/m2/README.md).

For real WebSocket and PTY checks, run `scripts/check-pty.sh --toy-box ../toy-box`. The [disposable server procedure](Benchmarks/pty.md) also starts an isolated endpoint for the native demos.

Toy Box builds its Mac app with Command Line Tools, so the libraries it links must build without Xcode. CI checks this, and you can run the same build in a fresh shell with `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --target Thrush --scratch-path .build/command-line-tools`. The separate scratch path keeps it from rebuilding the Xcode toolchain's products.

The loopback check uses Bun’s built-in WebSocket server and Apple’s URLSession WebSocket client. To run the peer separately, use `bun scripts/loopback.ts --serve` and pass the printed base URL to the client.

Build the native Release demos with `scripts/build-demo.sh mac` and `scripts/build-demo.sh simulator`. See [running the mock-backed hosts](docs/demo.md) and [measuring the packaged renderer](Benchmarks/rendering.md).
