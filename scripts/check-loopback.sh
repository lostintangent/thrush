#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product ThrushLoopbackCheck
bin=$(swift build --show-bin-path)
bun scripts/loopback.ts "$bin/ThrushLoopbackCheck"
exec bun scripts/lifecycle-peer.ts "$bin/ThrushLoopbackCheck"
