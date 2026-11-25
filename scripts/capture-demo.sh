#!/bin/bash
# Capture just the real native Mac window, or the selected simulator framebuffer.
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
case "${1:-}" in
    mac)
        [[ $# == 3 ]] || { echo 'Usage: capture-demo.sh mac PID OUTPUT.png' >&2; exit 2; }
        window_id=$(xcrun swift -e '
            import CoreGraphics
            import Foundation
            let pid = Int(CommandLine.arguments[1])
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let window = windows.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
            }), let id = window[kCGWindowNumber as String] as? Int else { exit(1) }
            print(id)
        ' "$2")
        /usr/sbin/screencapture -x -o -l "$window_id" "$3" ;;
    simulator)
        [[ $# == 3 ]] || { echo 'Usage: capture-demo.sh simulator UDID OUTPUT.png' >&2; exit 2; }
        xcrun simctl io "$2" screenshot --mask=black "$3" ;;
    *) echo 'Usage: capture-demo.sh mac PID OUTPUT.png | simulator UDID OUTPUT.png' >&2; exit 2 ;;
esac
