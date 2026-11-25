#!/bin/sh
# Checks out Toy Box at the pinned revision and installs only what the conformance harness loads: the
# pinned xterm packages. Toy Box's other dependencies, including private ones, stay uninstalled.
#
#   scripts/prepare-reference.sh <directory>
#   scripts/check-conformance.sh <directory>
set -eu
cd "$(dirname "$0")/.."
[ $# -eq 1 ] || { echo "Usage: scripts/prepare-reference.sh <directory>" >&2; exit 2; }
checkout=$1
pin=Fixtures/reference/conformance/reference.json

revision=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["reference"]["toyBox"])' "$pin")
git init -q "$checkout"
git -C "$checkout" fetch -q --depth 1 https://github.com/lostintangent/toy-box "$revision"
git -C "$checkout" checkout -q --detach FETCH_HEAD

# Toy Box's manifest and registry settings never apply, because the packages install in a scratch project.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
python3 -c 'import json, sys
packages = json.load(open(sys.argv[1]))["reference"]["packages"]
json.dump({"private": True, "dependencies": packages}, open(sys.argv[2], "w"), indent=1)' \
    "$pin" "$scratch/package.json"
(cd "$scratch" && bun install --silent)
rm -rf "$checkout/node_modules"
mv "$scratch/node_modules" "$checkout/node_modules"
