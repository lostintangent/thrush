#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product ThrushWebSocketCheck
bin=$(swift build --show-bin-path)
bun Tests/ThrushWebSocketCheck/first-bytes-peer.ts "$bin/ThrushWebSocketCheck"
exec bun Tests/ThrushWebSocketCheck/lifecycle-peer.ts "$bin/ThrushWebSocketCheck"
