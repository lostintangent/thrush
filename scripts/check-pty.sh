#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

usage='Usage: scripts/check-pty.sh [--readers | --recovery] [--endpoint http://127.0.0.1:PORT]'
mode=smoke
endpoint=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --readers|--recovery)
            [ "$mode" = smoke ] || { echo "$usage" >&2; exit 2; }
            mode=${1#--}
            shift ;;
        --endpoint)
            [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$endpoint" ] || { echo "$usage" >&2; exit 2; }
            endpoint=$2
            shift 2 ;;
        --help|-h) echo "$usage"; exit 0 ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
done
set --
if [ -n "$endpoint" ]; then set -- --endpoint "$endpoint"; fi
check=check
if [ "$mode" != smoke ]; then check=readers; fi
if [ "$mode" = recovery ]; then set -- --recovery "$@"; fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c release --product ThrushPTYCheck
if [ -z "$endpoint" ]; then swift build -c release --product ThrushServer; fi
bin=$(swift build -c release --show-bin-path)
if [ -z "$endpoint" ]; then set -- --server-binary "$bin/ThrushServer" "$@"; fi
exec python3 -B "scripts/pty/$check.py" "$bin/ThrushPTYCheck" "$@"
