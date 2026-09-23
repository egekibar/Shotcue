#!/bin/bash
# Notarizes dist/<App>-<version>.dmg with Apple, staples the ticket and rewrites its .sha256 (stapling changes the
# file). The DMG and the app inside must be signed with a Developer ID; `make notarize SIGN_IDENTITY='…'` builds both.
# Credentials come from a notarytool keychain profile, stored once (docs/distribution.md):
#   xcrun notarytool store-credentials shotcue-notary --apple-id <email> --team-id <TEAMID>
# Usage: scripts/notarize.sh [AppName]     (NOTARY_PROFILE overrides the profile name)
set -euo pipefail
APP_NAME="${1:-Shotcue}"
PROFILE="${NOTARY_PROFILE:-shotcue-notary}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="$DIST/$DMG_NAME"

[ -f "$DMG" ] || { echo "$DMG missing; run make dmg" >&2; exit 1; }
codesign -dvv "$DMG" 2>&1 | grep -q '^Authority=Developer ID Application: ' ||
  { echo "$DMG_NAME is not signed with a Developer ID; build it with SIGN_IDENTITY='Developer ID Application: …'" >&2; exit 1; }

RESULT="$(mktemp "${TMPDIR:-/tmp}/$APP_NAME-notary.XXXXXX")"
trap 'rm -f "$RESULT"' EXIT
echo "Submitting $DMG_NAME to Apple (this usually takes a few minutes)…"
# notarytool can exit 0 with an Invalid verdict, so the JSON status decides.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT" || true
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)"
if [ "$STATUS" != Accepted ]; then
  echo "notarization status: $STATUS" >&2
  cat "$RESULT" >&2
  ID="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || true)"
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
  exit 1
fi

xcrun stapler staple -q "$DMG"
xcrun stapler validate -q "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG"
(cd "$DIST" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null)
echo "Notarized and stapled: $DMG"
cat "$DMG.sha256"
