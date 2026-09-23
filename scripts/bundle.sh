#!/bin/bash
# Builds <App>.app from a SwiftPM binary and signs it.
# Usage: scripts/bundle.sh [AppName] [BundleID] [SigningIdentity] [Configuration]
#   Configuration debug (default): dist/<App>.app from the debug binary — the bundle `make install` copies.
#   Configuration release:         dist/release/<App>.app from the arm64 release binary — the bundle `make dmg` packs.
#   Build that configuration first (`swift build [-c release]`; the Makefile does). SigningIdentity defaults to
#   $SIGN_IDENTITY, then "Shotcue Dev"; when the keychain does not list it, the bundle is signed ad-hoc. A
#   "Developer ID Application: …" identity gets a secure timestamp (notarization needs it) and is never replaced.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
BUNDLE_ID="${2:-com.shotcue.app}"
IDENTITY="${3:-${SIGN_IDENTITY:-Shotcue Dev}}"
CONFIG="${4:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$CONFIG" in
  debug) OUT_DIR="$ROOT/dist" ;;
  release) OUT_DIR="$ROOT/dist/release" ;;
  *) echo "unknown configuration '$CONFIG' (expected debug or release)" >&2; exit 1 ;;
esac
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
[ -x "$BIN_DIR/$APP_NAME" ] || { echo "$BIN_DIR/$APP_NAME missing; run swift build -c $CONFIG first" >&2; exit 1; }
APP="$OUT_DIR/$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
# The release bundle is what ships, and Shotcue supports Apple Silicon only.
if [ "$CONFIG" = release ]; then
  lipo "$APP/Contents/MacOS/$APP_NAME" -verify_arch arm64 || { echo "release binary has no arm64 slice" >&2; exit 1; }
fi
# SwiftPM resource bundles (if any dependency ships one) live next to the binary.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/" && cp -R "$b" "$APP/Contents/MacOS/"
done
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" \
  "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Nested code is signed before its container. Swift Build signs resource bundles (ad-hoc) in debug builds only, so
# the release copies in Contents/MacOS arrive unsigned and fail strict verification; signed copies are left as is.
sign_nested() {
  local b
  for b in "$APP/Contents/MacOS"/*.bundle; do
    [ -e "$b" ] || continue
    codesign --verify "$b" 2>/dev/null || codesign --force "$@" "$b"
  done
}
# A Developer ID build is meant for notarization, which needs a secure timestamp and must never fall back to ad-hoc.
TIMESTAMP=--timestamp=none
case "$IDENTITY" in
  "Developer ID Application:"*) TIMESTAMP=--timestamp ;;
esac
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$IDENTITY\""; then
  sign_nested "$TIMESTAMP" --sign "$IDENTITY"
  codesign --force --options runtime "$TIMESTAMP" \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign "$IDENTITY" "$APP"
elif [ "$TIMESTAMP" = --timestamp ]; then
  echo "signing identity '$IDENTITY' is not in the keychain; see docs/distribution.md" >&2
  exit 1
else
  echo "WARNING: signing identity '$IDENTITY' not found. Run scripts/make-cert.sh once." >&2
  echo "         Falling back to ad-hoc signing: TCC permissions will NOT survive rebuilds." >&2
  sign_nested --sign -
  codesign --force --options runtime \
    --entitlements "$ROOT/Resources/Shotcue.entitlements" --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Bundled and signed: $APP"
