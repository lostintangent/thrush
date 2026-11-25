#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product ThrushPTYCheck
bin=$(swift build -c release --show-bin-path)
check=check
if [ "${1:-}" = "--recovery" ]; then
    check=readers
elif [ "${1:-}" = "--readers" ]; then
    shift
    check=readers
fi
exec python3 "scripts/pty/$check.py" "$bin/ThrushPTYCheck" "$@"
