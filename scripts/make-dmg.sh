#!/bin/bash
# Packs dist/release/<App>.app into dist/<App>-<version>.dmg (compressed, read-only) and writes its checksum to
# dist/<App>-<version>.dmg.sha256 (`shasum -a 256` format). The volume "<App> <version>" holds the app and an
# Applications symlink and shows the app icon. The version comes from the bundle's Info.plist.
# Built-in tools only; the scratch image is mounted with -nobrowse under a temp dir, so Finder never shows it.
# Usage: scripts/make-dmg.sh [AppName]     (run `make bundle-release` first; `make dmg` does both)
set -euo pipefail
APP_NAME="${1:-Shotcue}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/release/$APP_NAME.app"
ICON="$ROOT/Resources/AppIcon.icns"
PLIST_BUDDY=/usr/libexec/PlistBuddy

[ -d "$APP" ] || { echo "dist/release/$APP_NAME.app missing; run make bundle-release" >&2; exit 1; }
[ -f "$ICON" ] || { echo "$ICON missing" >&2; exit 1; }
VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SOURCE_VERSION="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
if [ "$VERSION" != "$SOURCE_VERSION" ]; then
  echo "stale bundle: it is $VERSION, Resources/Info.plist says $SOURCE_VERSION; run make bundle-release" >&2
  exit 1
fi
codesign --verify --deep --strict "$APP"

VOLNAME="$APP_NAME $VERSION"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG="$DIST/$DMG_NAME"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/$APP_NAME-dmg.XXXXXX")" && pwd -P)"
STAGE="$WORK/stage"
MNT="$WORK/mnt"

# `mount` lists the canonical path, hence `pwd -P` above. No `grep -q`: with pipefail an early exit could fail it.
is_mounted() { mount | grep -F " on $MNT (" >/dev/null; }
detach_scratch() {
  local attempt
  for attempt in 1 2 3 4 5; do
    hdiutil detach -quiet "$MNT" && return 0
    sleep 1
  done
  hdiutil detach -quiet -force "$MNT"
}
cleanup() {
  if is_mounted; then detach_scratch || true; fi
  # Never delete through a mount point that is still attached.
  if is_mounted; then
    echo "WARNING: could not detach $MNT; leaving $WORK in place" >&2
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A failed run must not leave a DMG next to a checksum of another build.
rm -f "$DMG" "$DMG.sha256"
mkdir -p "$STAGE" "$MNT"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp "$ICON" "$STAGE/.VolumeIcon.icns"

# 1. Read-write HFS+ image sized to the staged folder.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$WORK/rw.dmg"

# 2. Volume icon: Finder uses /.VolumeIcon.icns when the root folder carries the custom-icon flag.
hdiutil attach -quiet -nobrowse -noautoopen -noverify -readwrite -mountpoint "$MNT" "$WORK/rw.dmg"
SetFile -a V "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
case "$(GetFileInfo -a "$MNT")" in
  *C*) ;;
  *) echo "the custom-icon flag did not stick on the volume root" >&2; exit 1 ;;
esac
detach_scratch

# 3. Compressed read-only image, verified, then moved into dist/ with its checksum.
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$WORK/$DMG_NAME"
hdiutil verify -quiet "$WORK/$DMG_NAME"
# A Developer ID app gets a DMG signed by the same identity, ready for scripts/notarize.sh.
DEVELOPER_ID="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -n 1)"
if [ -n "$DEVELOPER_ID" ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$WORK/$DMG_NAME"
  codesign --verify --strict "$WORK/$DMG_NAME"
fi
mv -f "$WORK/$DMG_NAME" "$DMG"
(cd "$DIST" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" && shasum -a 256 -c "$DMG_NAME.sha256" >/dev/null)
echo "Wrote $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
