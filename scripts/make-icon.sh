#!/bin/bash
# Builds Resources/AppIcon.icns from the CoreGraphics-drawn 1024x1024 master PNG.
# Usage: scripts/make-icon.sh              (renders the glyph, then packs the .icns)
#        scripts/make-icon.sh master.png   (packs an existing 1024x1024 PNG instead)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="${1:-}"

if [ -z "$MASTER" ]; then
  MASTER="$WORK/AppIcon-1024.png"
  swift "$ROOT/scripts/render-icon.swift" "$MASTER"
fi
[ -f "$MASTER" ] || { echo "master PNG not found: $MASTER" >&2; exit 1; }
W="$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth/{print $2}')"
H="$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight/{print $2}')"
[ "$W" = "1024" ] && [ "$H" = "1024" ] || { echo "master must be 1024x1024, got ${W}x${H}" >&2; exit 1; }

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
# name:pixels — iconutil requires exactly these file names for a complete macOS icon.
for pair in \
  icon_16x16:16 icon_16x16@2x:32 \
  icon_32x32:32 icon_32x32@2x:64 \
  icon_128x128:128 icon_128x128@2x:256 \
  icon_256x256:256 icon_256x256@2x:512 \
  icon_512x512:512 icon_512x512@2x:1024
do
  name="${pair%%:*}"; px="${pair##*:}"
  sips -s format png -z "$px" "$px" "$MASTER" --out "$SET/$name.png" >/dev/null
done
# A silently skipped size would still pack into a valid but incomplete .icns.
COUNT="$(find "$SET" -name '*.png' | wc -l | tr -d ' ')"
[ "$COUNT" = "10" ] || { echo "expected 10 iconset PNGs, got $COUNT" >&2; exit 1; }

mkdir -p "$ROOT/Resources"
iconutil -c icns "$SET" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns ($(du -h "$ROOT/Resources/AppIcon.icns" | cut -f1))"
