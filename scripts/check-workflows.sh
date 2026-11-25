#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bun install --cwd Fixtures/reference --frozen-lockfile --silent
bun test scripts/workflow-peer.test.ts
swift build --product ThrushLoopbackCheck
bin=$(swift build --show-bin-path)
exec bun scripts/check-workflows.ts "$bin/ThrushLoopbackCheck"
