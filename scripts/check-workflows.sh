#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bun test scripts/workflow-peer.test.ts
swift build --product ThrushLoopbackCheck
bin=$(swift build --show-bin-path)
exec bun scripts/check-workflows.ts "$bin/ThrushLoopbackCheck"
