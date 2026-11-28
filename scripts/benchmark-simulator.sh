#!/bin/bash
# The selected simulator must already be booted. Only its demo process is controlled.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ $# == 3 || ( ${4:-} == --installed && $# -le 5 ) ]] || {
    echo 'Usage: benchmark-simulator.sh UDID SIMULATOR_APP OUTPUT.json [--installed [DOCUMENTS_DIR]]' >&2
    exit 2
}
device=$1
app=$2
output=$3
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
if [[ ${4:-} != --installed ]]; then xcrun simctl install "$device" "$app"; fi
documents=${5:-}
if [[ -z "$documents" ]]; then
    documents="$(xcrun simctl get_app_container "$device" "$identifier" data)/Documents"
fi
report="$documents/render.json"
failure="$documents/render-error.txt"
ready="$report.background-ready"
entered="$report.background-entered"
rm -f "$ready" "$entered" "$failure" "$report"
xcrun simctl launch --terminate-running-process "$device" "$identifier" --benchmark
wait_for() {
    local path=$1
    local deadline=$((SECONDS + 100))
    while [[ ! -f "$path" ]]; do
        [[ ! -f "$failure" ]] || { cat "$failure" >&2; exit 1; }
        (( SECONDS < deadline )) || { echo "Timed out waiting for $(basename "$path")" >&2; exit 1; }
        sleep 0.25
    done
}
wait_for "$ready"
xcrun simctl launch "$device" com.apple.Preferences
# Settings may launch before UIKit finishes moving Thrush into the background.
# Start the hold after Thrush took its native submission counter snapshot.
wait_for "$entered"
sleep 2
xcrun simctl launch "$device" "$identifier"
wait_for "$report"
mkdir -p "$(dirname "$output")"
cp "$report" "$output"
python3 "$(dirname "$0")/../Benchmarks/check-render-report.py" "$output"
