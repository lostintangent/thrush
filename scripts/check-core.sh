#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Implementation and test names describe terminal behavior. The reference tooling names its oracle.
# The server supplies the standard terminfo name to programs such as Vim.
if grep -riIn 'xterm' Sources Tests | grep -v 'Sources/ThrushServer/ThrushServerMain.swift:.*"TERM": "xterm-256color"'; then
    echo "Describe terminal behavior directly in Sources and Tests. Keep oracle names in the reference tooling." >&2
    exit 1
fi

# Inspect every ThrushCore import, including inactive #if branches, with the Xcode parser.
swift=$(xcrun --find swift)
host="$(dirname "$swift")/../lib/swift/host"
if [ ! -d "$host/SwiftSyntax.swiftmodule" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    swift=$(xcrun --find swift)
    host="$(dirname "$swift")/../lib/swift/host"
fi
exec "$swift" -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host" scripts/check-core.swift "$swift"
