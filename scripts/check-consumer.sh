#!/bin/sh
set -eu

cd "$(dirname "$0")/../examples/headless-consumer"
swift build -c release --product Consumer
bin="$(swift build -c release --show-bin-path)/Consumer"
"$bin"

libraries=$(otool -L "$bin")
if echo "$libraries" | grep -Ei '(Foundation[^/]*\.framework/|/lib[^/]*Foundation[^/]*\.dylib)' >&2; then
    echo 'The headless consumer links Foundation.' >&2
    exit 1
fi
echo 'The headless consumer links no Foundation framework or library.'
