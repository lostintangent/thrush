#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
bun test Tests/ThrushWebSocketCheck/workflow-peer.test.ts
swift build --product ThrushWebSocketCheck
bin=$(swift build --show-bin-path)
exec bun Tests/ThrushWebSocketCheck/check-workflows.ts "$bin/ThrushWebSocketCheck"
