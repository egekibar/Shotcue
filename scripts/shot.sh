#!/bin/bash
# Launches the installed app (asking it to open the library window) and screenshots each of its windows.
# Prints the PNG paths. Requires Screen Recording permission for the process running this script.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
OUT_DIR="${2:-/tmp/shotcue-shots}"
APP="$HOME/Applications/$APP_NAME.app"
mkdir -p "$OUT_DIR"
open -a "$APP" --env SHOTCUE_OPEN_LIBRARY=1
sleep 2
WINDOW_IDS="$(swift - "$APP_NAME" <<'EOF'
import CoreGraphics
import Foundation
let owner = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == owner {
    if let id = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: Any],
       (b["Height"] as? Double ?? 0) > 40 { print(id) }
}
EOF
)"
[ -n "$WINDOW_IDS" ] || { echo "No on-screen windows for $APP_NAME" >&2; exit 1; }
i=0
for id in $WINDOW_IDS; do
  i=$((i+1)); f="$OUT_DIR/window-$i.png"
  screencapture -x -o -l "$id" "$f" && echo "$f"
done
