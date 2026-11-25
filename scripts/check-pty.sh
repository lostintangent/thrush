#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product ThrushPTYCheck
bin=$(swift build -c release --show-bin-path)
exec python3 scripts/pty/check.py "$bin/ThrushPTYCheck" "$@"
