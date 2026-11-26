#!/bin/bash
# Build a separate SwiftPM app whose only dependency is the public Thrush product.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-mac}" in
    mac) sdk=macosx; triple="$(uname -m)-apple-macosx27.0"; platform=MACOS ;;
    simulator) sdk=iphonesimulator; triple="$(uname -m)-apple-ios27.0-simulator"; platform=IOSSIMULATOR ;;
    device) sdk=iphoneos; triple=arm64-apple-ios27.0; platform=IOS ;;
    *) echo "Usage: scripts/check-swiftui-example.sh [mac|simulator|device]" >&2; exit 2 ;;
esac
if [[ "$sdk" != macosx ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi

sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
build=(xcrun swift build -c release --package-path "$root/examples/swiftui"
       --scratch-path "$root/.build/swiftui-example/$sdk" --sdk "$sdk_path" --triple "$triple"
       --explicit-target-dependency-import-check error --product SwiftUIExample)
"${build[@]}"
binary=$("${build[@]}" --show-bin-path)/SwiftUIExample
xcrun vtool -show-build "$binary" | awk -v expected="$platform" '
    $1 == "platform" && $2 == expected { found = 1 }
    END { if (!found) exit 1 }
'
echo "Linked the external SwiftUIExample for $triple ($platform)."
