#!/bin/bash
# Run the actual UIKit, Metal and recorded workflow tests on one named simulator.
set -euo pipefail
if [[ $# != 1 || ! $1 =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
    echo "Usage: scripts/check-ios-ui.sh SIMULATOR-UDID" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
package=$(mktemp -d "${TMPDIR:-/tmp}/thrush-ios-ui.XXXXXX")
trap 'rm -rf "$package"' EXIT
ln -s "$root/Sources" "$package/Sources"
ln -s "$root/Tests" "$package/Tests"
ln -s "$root/Fixtures" "$package/Fixtures"

# Xcode's package-wide scheme includes the Mac-only benchmark executable. Use the
# same sources and fixtures with only the targets needed by these tests.
cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ThrushUIVerification",
    platforms: [.iOS("27.0")],
    products: [.library(name: "ThrushUI", targets: ["ThrushUI"])],
    targets: [
        .target(name: "Thrush"),
        .target(name: "ThrushConnection", dependencies: ["Thrush"]),
        .target(name: "ThrushUI", dependencies: ["Thrush", "ThrushConnection"]),
        .target(name: "ThrushFixtures", dependencies: ["Thrush"], path: "Fixtures",
                exclude: ["reference"], resources: [.copy("first-bytes.json"), .copy("replays")]),
        .testTarget(name: "ThrushUITests", dependencies: ["ThrushUI", "Thrush", "ThrushConnection", "ThrushFixtures"]),
    ],
    swiftLanguageModes: [.v6]
)
SWIFT

cd "$package"
xcodebuild -scheme ThrushUIVerification \
    -destination "platform=iOS Simulator,id=$1" \
    -derivedDataPath "$root/.build/ios-ui/$1" \
    -parallel-testing-enabled NO test
