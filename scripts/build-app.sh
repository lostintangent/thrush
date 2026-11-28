#!/bin/bash
# Build the sample app, or the proofs that mount its window, and wrap it in a launchable application.
set -euo pipefail
cd "$(dirname "$0")/.."
usage="Usage: scripts/build-app.sh sample|proofs mac|simulator"
kind=${1:-}
platform=${2:-}
case "$kind" in
    # The sample shares scripts/check-sample.sh's build, so wrapping it after that check costs only packaging.
    sample) package=(--package-path examples/swiftui --explicit-target-dependency-import-check error); product=Sample ;;
    proofs) package=(); product=ThrushProofs ;;
    *) echo "$usage" >&2; exit 2 ;;
esac
case "$platform" in
    mac) sdk=macosx; minimum=27.0; triple="$(uname -m)-apple-macosx$minimum" ;;
    simulator)
        export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
        sdk=iphonesimulator
        # SwiftPM records the minimum as the app's SDK too, and the Duo's vertical status bar needs 27.1.
        minimum=27.2
        triple="$(uname -m)-apple-ios$minimum-simulator"
        ;;
    *) echo "$usage" >&2; exit 2 ;;
esac

out="$PWD/.build/$kind/$platform"
mkdir -p "$out"
stage=$(mktemp -d "$out/package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Thrush.app"
sdk_path=$(xcrun --sdk "$sdk" --show-sdk-path)
sdk_version=$(xcrun --sdk "$sdk" --show-sdk-version)
scratch="$out/swiftpm"
if [[ "$kind" == sample ]]; then scratch="$PWD/.build/sample/swiftpm/$sdk"; fi
build=(xcrun swift build -c release ${package[@]+"${package[@]}"} --scratch-path "$scratch" --sdk "$sdk_path" --triple "$triple"
       --product "$product")
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
cp "$bin/$product" "$executable/"
if [[ "$platform" == mac ]]; then
    iconset="$stage/thrush.iconset"
    mkdir "$iconset"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" docs/Thrush-app-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" docs/Thrush-app-icon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$resources/Thrush.icns"
else
    sips -z 180 180 docs/Thrush-app-icon.png --out "$resources/Icon60@3x.png" >/dev/null
    sips -z 120 120 docs/Thrush-app-icon.png --out "$resources/Icon60@2x.png" >/dev/null
fi

commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)
dirty=false
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then dirty=true; fi
toolchain=$(xcrun swift --version | head -1)
python3 - "$bundle/Info.plist" "$kind" "$product" "$platform" "$commit" "$dirty" "$toolchain" "$sdk_version" "$minimum" <<'PY'
import plistlib
import sys
path, kind, product, platform, commit, dirty, toolchain, sdk, minimum = sys.argv[1:]
info = dict(CFBundleDevelopmentRegion="en", CFBundleExecutable=product,
            CFBundleIdentifier="app.thrush." + kind, CFBundleName="Thrush", CFBundleDisplayName="Thrush",
            CFBundlePackageType="APPL", CFBundleShortVersionString="0.1", CFBundleVersion="1",
            CFBundleInfoDictionaryVersion="6.0", ThrushGitCommit=commit, ThrushWorktreeDirty=dirty == "true",
            ThrushToolchain=toolchain)
if platform == "mac":
    info.update(LSMinimumSystemVersion=minimum, NSHighResolutionCapable=True, NSPrincipalClass="NSApplication",
                CFBundleIconFile="Thrush", CFBundleSupportedPlatforms=["MacOSX"], DTSDKName="macosx"+sdk)
else:
    info.update(MinimumOSVersion=minimum, UIDeviceFamily=[1], LSRequiresIPhoneOS=True,
                CFBundleSupportedPlatforms=["iPhoneSimulator"], DTPlatformName="iphonesimulator",
                DTSDKName="iphonesimulator"+sdk, UILaunchScreen={},
                CFBundleIcons={"CFBundlePrimaryIcon": {"CFBundleIconFiles": ["Icon60"]}},
                UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False},
                UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait",
                    "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"])
info["NSLocalNetworkUsageDescription"] = "Connect to the Thrush terminal server running on your Mac."
info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
with open(path, "wb") as f:
    plistlib.dump(info, f)
PY
if [[ -n "$(find "$app" \( -name '*.bundle' -o -name '*.metallib' \) -print -quit)" ]]; then
    echo "Unexpected package or shader resource in the app." >&2
    exit 1
fi
codesign --force --sign - "$app" >/dev/null
codesign --verify --strict "$app"
# Publish the signed directory atomically. Two simultaneous builds can both finish without
# leaving a partially replaced app. On a swap, the EXIT trap removes the previous package.
python3 - "$app" "$out/Thrush.app" <<'PUBLISH'
import ctypes
import errno
import os
import sys

source, target = sys.argv[1:]
try:
    os.rename(source, target)
except OSError as error:
    if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
        raise
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename_swap = 0x00000002  # <stdio.h> RENAME_SWAP
    if rename(os.fsencode(source), os.fsencode(target), rename_swap) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), target)
PUBLISH
echo "$out/Thrush.app"
