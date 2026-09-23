#!/bin/bash
# Builds Shotcue.app under dist/ from the SwiftPM debug binary and signs it.
# Usage: scripts/bundle.sh [AppName] [BundleID] [SigningIdentity]
set -euo pipefail
APP_NAME="${1:-Shotcue}"
BUNDLE_ID="${2:-com.shotcue.app}"
IDENTITY="${3:-Shotcue Dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$(swift build --package-path "$ROOT" --show-bin-path)"
APP="$ROOT/dist/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# SwiftPM resource bundles (if any dependency ships one) live next to the binary.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && cp -R "$b" "$APP/Contents/MacOS/"
done
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign "$IDENTITY" "$APP"
else
  echo "WARNING: signing identity '$IDENTITY' not found. Run scripts/make-cert.sh once." >&2
  echo "         Falling back to ad-hoc signing: TCC permissions will NOT survive rebuilds." >&2
  codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Bundled and signed: $APP"
