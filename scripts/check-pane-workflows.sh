#!/bin/bash
# Run the three recorded workflows in a packaged native terminal pane.
# Usage: scripts/check-pane-workflows.sh mac OUTPUT [shell|vim|codex ...]
#        scripts/check-pane-workflows.sh simulator BOOTED_IPHONE_UDID|new OUTPUT [shell|vim|codex ...]
# Select an iPhone reserved for this task. The runner installs the app on that device.
# The checkpoint oracle is the pinned reference in Fixtures/reference, which the runner installs first.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if [[ ${1:-} == mac ]]; then
    exec caffeinate -d -u python3 scripts/check-pane-workflows.py "$@"
fi
exec python3 scripts/check-pane-workflows.py "$@"
