#!/bin/bash
# Builds the thrush package and checks it. Through every program capture, the WebAssembly module
# returns the same replies and replays as native ThrushCore, byte for byte. The packed tarball then
# installs, type-checks and runs under Bun, under Node 22.18 or later and as a Bun-compiled binary.
# Wasm/build.sh lists what the build needs, and the native build uses the swift on the PATH.
set -euo pipefail
cd "$(dirname "$0")/../Wasm"
./build.sh
swift build -c release --product NativeReplay --scratch-path .build/native
bun test/identity.mjs .build/native/release/NativeReplay

project=$(mktemp -d)
trap 'rm -rf "$project"' EXIT
cp test/package.ts "$project"
tarball="$PWD/out/thrush-wasm.tgz"
cd "$project"
echo '{ "type": "module" }' > package.json
echo '{ "compilerOptions": { "strict": true, "lib": ["es2022", "dom"] } }' > tsconfig.json
bun add "$tarball"
bun package.ts
node package.ts
bun build package.ts --check --compile --outfile package
rm -rf node_modules
./package
