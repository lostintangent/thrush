#!/bin/bash
# The selected simulator must already be booted. Only its demo process is controlled.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ $# == 3 ]] || { echo 'Usage: benchmark-simulator.sh UDID SIMULATOR_APP OUTPUT.json' >&2; exit 2; }
device=$1
app=$2
output=$3
identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun simctl install "$device" "$app"
data=$(xcrun simctl get_app_container "$device" "$identifier" data)
report="$data/Documents/render.json"
failure="$data/Documents/render-error.txt"
marker="$report.background-ready"
rm -f "$marker" "$failure" "$report"
xcrun simctl launch --terminate-running-process "$device" "$identifier" --benchmark --lifecycle-check
wait_for() {
    local path=$1
    local deadline=$((SECONDS + 100))
    while [[ ! -f "$path" ]]; do
        [[ ! -f "$failure" ]] || { cat "$failure" >&2; exit 1; }
        (( SECONDS < deadline )) || { echo "Timed out waiting for $(basename "$path")" >&2; exit 1; }
        sleep 0.25
    done
}
wait_for "$marker"
xcrun simctl launch "$device" com.apple.Preferences
sleep 2
xcrun simctl launch "$device" "$identifier"
wait_for "$report"
mkdir -p "$(dirname "$output")"
cp "$report" "$output"
python3 "$(dirname "$0")/check-render-report.py" "$output"
