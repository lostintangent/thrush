#!/bin/bash
# Build either native host from SwiftPM and package the platform's compiled shader.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
platform=${1:-}
case "$platform" in
    mac) sdk=macosx; triple="$(uname -m)-apple-macosx27.0" ;;
    simulator) sdk=iphonesimulator; triple="$(uname -m)-apple-ios27.0-simulator" ;;
    *) echo "Usage: scripts/build-demo.sh mac|simulator" >&2; exit 2 ;;
esac

out="$PWD/.build/demo/$platform"
mkdir -p "$out"
stage=$(mktemp -d "$out/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Thrush.app"
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
build=(xcrun swift build -c release --scratch-path "$out/swiftpm" --sdk "$sdk_path" --triple "$triple" --product ThrushDemo)
"${build[@]}"
bin=$("${build[@]}" --show-bin-path)
if [[ "$platform" == mac ]]; then
    bundle="$app/Contents"
    executable="$bundle/MacOS"
    resources="$bundle/Resources"
else
    bundle="$app"
    executable="$app"
    resources="$app"
fi
mkdir -p "$executable" "$resources"
cp "$bin/ThrushDemo" "$executable/"
shader_bundle="$resources/Thrush_ThrushUI.bundle"
ditto "$bin/Thrush_ThrushUI.bundle" "$shader_bundle"
shader_resources="$shader_bundle"
if [[ -d "$shader_bundle/Contents/Resources" ]]; then
    shader_resources="$shader_bundle/Contents/Resources"
fi
# Verify that SwiftPM's processed package resource contains the SDK-specific library.
test -s "$shader_resources/default.metallib"

if [[ "$platform" == mac ]]; then
    iconset="$stage/thrush.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" docs/Thrush-channel-white.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" docs/Thrush-channel-white.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$resources/Thrush.icns"
else
    sips -z 180 180 docs/Thrush-channel-white.png --out "$resources/Icon60@3x.png" >/dev/null
    sips -z 120 120 docs/Thrush-channel-white.png --out "$resources/Icon60@2x.png" >/dev/null
fi

commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then dirty=true; fi
toolchain=$(xcrun swift --version | head -1)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
python3 - "$bundle/Info.plist" "$platform" "$commit" "$dirty" "$toolchain" "$sdk_version" <<'PY'
import plistlib
import sys
path, platform, commit, dirty, toolchain, sdk = sys.argv[1:]
info = dict(CFBundleDevelopmentRegion="en", CFBundleExecutable="ThrushDemo",
            CFBundleIdentifier="app.thrush.demo", CFBundleName="Thrush", CFBundleDisplayName="Thrush",
            CFBundlePackageType="APPL", CFBundleShortVersionString="0.1", CFBundleVersion="1",
            CFBundleInfoDictionaryVersion="6.0", ThrushGitCommit=commit, ThrushWorktreeDirty=dirty == "true",
            ThrushToolchain=toolchain)
if platform == "mac":
    info.update(LSMinimumSystemVersion="27.0", NSHighResolutionCapable=True, NSPrincipalClass="NSApplication",
                CFBundleIconFile="Thrush", CFBundleSupportedPlatforms=["MacOSX"], DTSDKName="macosx"+sdk)
else:
    info.update(MinimumOSVersion="27.0", UIDeviceFamily=[1], LSRequiresIPhoneOS=True,
                CFBundleSupportedPlatforms=["iPhoneSimulator"], DTPlatformName="iphonesimulator",
                DTSDKName="iphonesimulator"+sdk, UILaunchScreen={},
                CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["Icon60"]}},
                UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False,
                    "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [
                        {"UISceneConfigurationName": "Terminal", "UISceneDelegateClassName": "ThrushPhoneScene"}]}},
                UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
info["NSLocalNetworkUsageDescription"] = "Connect to the Thrush demo terminal running on your Mac."
info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
with open(path, "wb") as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - "$app" >/dev/null
codesign --verify --strict "$app"
rm -rf "$out/Thrush.app"
mv "$app" "$out/Thrush.app"
echo "$out/Thrush.app"
