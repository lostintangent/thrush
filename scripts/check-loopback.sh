#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --product ThrushLoopbackCheck
bin=$(swift build --show-bin-path)
exec bun scripts/loopback.ts "$bin/ThrushLoopbackCheck"
