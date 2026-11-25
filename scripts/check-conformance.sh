#!/bin/sh
# Checks ThrushCore against the pinned reference emulator. Every conformance case replays through the
# reference and through a release build of ThrushConformance, and the check fails if a generated case,
# known gap or reference defect would change. Then the Swift conformance tests run.
#
#   scripts/check-conformance.sh [toy-box checkout] [--write] [--report <gaps.md>]
#
# The Toy Box checkout defaults to ../toy-box, at the pinned revision with its dependencies installed.
# --write regenerates the files instead of checking them. --report also writes the ranked gap report.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

toy_box=../toy-box
check=--check
report=
while [ $# -gt 0 ]; do
    case "$1" in
        --write) check=; shift ;;
        --report) report=$2; shift 2 ;;
        *) toy_box=$1; shift ;;
    esac
done
toy_box=$(cd "$toy_box" && pwd)

swift build --product ThrushConformance -c release
thrush="$(swift build -c release --show-bin-path)/ThrushConformance"
NODE_PATH="$toy_box/node_modules/@xterm/xterm/src" bun Fixtures/reference/conformance/harness.mjs "$toy_box" \
    --thrush "$thrush" $check ${report:+--report "$report"}
swift test --filter ThrushConformanceTests
