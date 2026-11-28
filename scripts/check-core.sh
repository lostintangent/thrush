#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Implementation and test names describe terminal behavior. The reference tooling names its oracle.
# The server supplies the standard terminfo name to programs such as Vim.
if grep -riIn 'xterm' Sources Tests | grep -v 'Sources/ThrushServer/ThrushServerMain.swift:.*"TERM": "xterm-256color"'; then
    echo "Describe terminal behavior directly in Sources and Tests. Keep oracle names in the reference tooling." >&2
    exit 1
fi

# ThrushCore uses only the standard library, so the word never appears in it. This catches every form,
# such as `public import` and `import struct`, including inside inactive #if branches.
if grep -rnw 'import' Sources/ThrushCore; then
    echo "ThrushCore imports nothing. Keep it to the Swift standard library." >&2
    exit 1
fi
if find Sources/ThrushCore -type f ! -name '*.swift' | grep .; then
    echo "ThrushCore holds only Swift sources." >&2
    exit 1
fi

# The core target declares nothing beyond its name, so it has no dependencies, resources, settings or
# plugins. The one product is the Thrush library, so the core stays internal.
products=$(sed -n '/^ *products: \[/,/^ *\],/p' Package.swift | sed '1d;$d' | tr -d ' ')
if ! grep -Eq '^[[:space:]]*\.target\(name: "ThrushCore"\),$' Package.swift \
    || [ "$products" != '.library(name:"Thrush",targets:["Thrush"]),' ]; then
    echo "ThrushCore is a plain internal target: no dependencies, resources, settings, plugins or product." >&2
    exit 1
fi
echo "ThrushCore imports nothing and declares no dependencies."
