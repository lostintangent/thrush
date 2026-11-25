#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Inspect every ThrushCore import, including inactive #if branches, with the Xcode parser.
swift=$(xcrun --find swift)
host="$(dirname "$swift")/../lib/swift/host"
if [ ! -d "$host/SwiftSyntax.swiftmodule" ]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    swift=$(xcrun --find swift)
    host="$(dirname "$swift")/../lib/swift/host"
fi
exec "$swift" -I "$host" -L "$host" -Xlinker -rpath -Xlinker "$host" scripts/check-core.swift "$swift"
