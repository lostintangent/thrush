#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product ThrushLoopbackCheck
swift build -c release --product ThrushServer
bin=$(swift build -c release --show-bin-path)
exec python3 -B scripts/pty/check.py "$bin/ThrushLoopbackCheck"
