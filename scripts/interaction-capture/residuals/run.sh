#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$1
cd "$root"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
probe=Tests/ThrushTests/ProducerProbe.swift
test ! -e "$probe" || { echo "Existing test probe at $probe" >&2; exit 1; }
cp "$here/ProducerProbe.swift" "$probe"
bun "$here/peer.ts" > "$here/port" 2> "$here/peer.log" &
server=$!
trap 'kill "$server" 2>/dev/null || true; if cmp -s "$probe" "$here/ProducerProbe.swift"; then rm "$probe"; fi' EXIT
for n in $(seq 1 50); do test -s "$here/port" && break; sleep 0.05; done
export THRUSH_DRAIN_URL="ws://127.0.0.1:$(cat "$here/port")"
swift test -c release --jobs 3 --filter measuredRealProducerMailbox > "$here/cutoff-probe.log" 2>&1
rg 'intermediate policy|drain-probe|Test run with' "$here/cutoff-probe.log"
