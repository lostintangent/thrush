#!/bin/bash
# Builds out/thrush-wasm.tgz: ThrushCore in Embedded Swift for WebAssembly, behind the Terminal class
# in index.js. It needs the swift.org Swift 6.4.2 toolchain with its Wasm SDK and binaryen's wasm-opt.
# SWIFT names that toolchain's swift when another comes first on the PATH, as Xcode's does, and
# SWIFT_SDKS the directory its SDKs are in when it isn't the default. VERSION sets the package's
# version, which a release takes from its tag.
set -euo pipefail
cd "$(dirname "$0")"
swift=${SWIFT:-swift}
version=${VERSION:-0.0.0}
if ! "$swift" --version 2>&1 | grep -q 'Swift version 6\.4\.2 '; then
    echo "Build thrush-wasm with the swift.org Swift 6.4.2 toolchain, setting SWIFT to its swift." >&2
    exit 1
fi

"$swift" build -c release --product ThrushWasm --swift-sdk swift-6.4.2-RELEASE_wasm-embedded \
    ${SWIFT_SDKS:+--swift-sdks-path "$SWIFT_SDKS"} --scratch-path .build/wasm
rm -rf out
mkdir -p out/package
wasm-opt -Oz --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext --enable-mutable-globals \
    --enable-nontrapping-float-to-int .build/wasm/release/ThrushWasm.wasm -o out/thrush.wasm

# The class carries the module as base64, so it starts without reading a file or awaiting a fetch.
printf '// ThrushCore built for WebAssembly, written by Wasm/build.sh.\nexport default "%s";\n' \
    "$(base64 < out/thrush.wasm | tr -d '\n')" > out/package/module.js
cp index.js index.d.ts ../LICENSE out/package/
sed "s/\"version\": \"0.0.0\"/\"version\": \"$version\"/" package.json > out/package/package.json
tar -czf out/thrush-wasm.tgz -C out package
printf 'thrush-wasm %s: module %d bytes, package %d bytes\n' "$version" "$(wc -c < out/thrush.wasm)" "$(wc -c < out/thrush-wasm.tgz)"
