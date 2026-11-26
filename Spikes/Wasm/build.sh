#!/bin/bash
# Builds ThrushCore for WebAssembly with the swift.org toolchain and its Wasm SDK, in full Swift and in
# Embedded Swift, then optimizes each with wasm-opt. TOOLCHAIN is the .xctoolchain directory, and SDKS
# the directory `swift sdk install --swift-sdks-path` installed swift-6.4.2-RELEASE_wasm into.
set -euo pipefail
cd "$(dirname "$0")"
: "${TOOLCHAIN:?set TOOLCHAIN to a swift.org 6.4.2 .xctoolchain}" "${SDKS:?set SDKS to the Swift SDKs path}"
mkdir -p out
features=(--enable-bulk-memory --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int)
for variant in full embedded; do
    sdk=swift-6.4.2-RELEASE_wasm
    flags=()
    if [ "$variant" = embedded ]; then
        sdk+=-embedded
        # Grapheme breaking and normalization read the stdlib's Unicode tables, which Embedded Swift links on request.
        flags=(-Xlinker -lswiftUnicodeDataTables)
    fi
    "$TOOLCHAIN/usr/bin/swift" build -c release --product ThrushWasm --swift-sdks-path "$SDKS" --swift-sdk "$sdk" \
        --scratch-path ".build-$variant" ${flags[@]+"${flags[@]}"}
    cp ".build-$variant/release/ThrushWasm.wasm" "out/$variant.raw.wasm"
    for level in O3 Oz; do
        wasm-opt "${features[@]}" "-$level" --strip-debug --strip-producers "out/$variant.raw.wasm" -o "out/$variant.$level.wasm"
    done
done
ln -sf embedded.O3.wasm out/thrush.wasm
for module in out/*.*.wasm; do
    printf "%-24s %9d bytes  gzip %8d  brotli %8d\n" "$module" "$(wc -c < "$module")" \
        "$(gzip -9c "$module" | wc -c)" "$(brotli -cq 11 "$module" | wc -c)"
done
