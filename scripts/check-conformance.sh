#!/bin/sh
# Checks ThrushCore against the pinned reference emulator. Every conformance case replays through the
# reference and through a release build of ThrushConformance, and the check fails if a generated case,
# known gap or reference defect would change. Then a terminal resumes from ThrushCore's replay after
# every write and resize of each recorded program, and the check fails if a replay gap would change.
# Then the Swift conformance tests run.
#
#   scripts/check-conformance.sh [--write] [--report <gaps.md>]
#
# The reference is the exact npm packages in Fixtures/reference/package.json, installed from its lockfile.
# --write regenerates the files instead of checking them. --report also writes the ranked gap report.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

check=--check
report=
while [ $# -gt 0 ]; do
    case "$1" in
        --write) check=; shift ;;
        --report) report=$2; shift 2 ;;
        *) echo "Usage: scripts/check-conformance.sh [--write] [--report <gaps.md>]" >&2; exit 64 ;;
    esac
done

bun install --cwd Fixtures/reference --frozen-lockfile --silent
swift build --product ThrushConformance -c release
thrush="$(swift build -c release --show-bin-path)/ThrushConformance"
bun Fixtures/reference/conformance/harness.mjs --thrush "$thrush" $check ${report:+--report "$report"}
bun Fixtures/reference/conformance/replays.mjs --thrush "$thrush" $check
swift test --filter ThrushConformanceTests
