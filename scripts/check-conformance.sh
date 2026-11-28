#!/bin/sh
# Checks ThrushCore against the pinned reference emulator. Every conformance case replays through the
# reference, and the check fails if a generated case would change. Then a terminal resumes from
# ThrushCore's replay after every write and resize of each recorded program, and the check fails if a
# replay gap would change. Then the Swift conformance tests replay every case through ThrushCore.
#
#   scripts/check-conformance.sh [--write]
#
# The reference is the exact npm packages in Fixtures/reference/package.json, installed from its lockfile.
# --write regenerates the files instead of checking them, and lists the known gaps and reference defects
# from a release build of ThrushConformance.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

check=--check
case "${1-}" in
    '') ;;
    --write) check= ;;
    *) echo "Usage: scripts/check-conformance.sh [--write]" >&2; exit 64 ;;
esac

bun install --cwd Fixtures/reference --frozen-lockfile --silent
swift build --product ThrushConformance -c release
thrush="$(swift build -c release --show-bin-path)/ThrushConformance"
if [ "$check" ]; then
    bun Fixtures/reference/conformance/harness.mjs --check
else
    bun Fixtures/reference/conformance/harness.mjs --thrush "$thrush"
fi
bun Fixtures/reference/conformance/replays.mjs --thrush "$thrush" $check
swift test --filter ThrushConformanceTests
