# Thrush

Thrush is a first-party Swift terminal emulator for macOS and iOS. [docs/plan.md](docs/plan.md) is the source of truth for requirements, the ontology, contracts, budgets and milestones. When work changes a decision the plan records, update the plan in the same change.

## Principles

- The `Thrush` target uses only the Swift standard library. No Foundation, Darwin or third-party code.
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

The Core owner fills this in as the package lands.
