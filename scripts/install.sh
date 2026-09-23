#!/bin/bash
# Copies dist/<App>.app to ~/Applications (stable path keeps TCC grants), restarting a running instance.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
INSTALL_DIR="${2:-$HOME/Applications}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/$APP_NAME.app"
[ -d "$SRC" ] || { echo "dist/$APP_NAME.app missing; run make bundle" >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
# A running instance gets SIGTERM and shuts itself down: runs in flight are stopped (up to ~12 s, bounded at 20 s by
# the app) and unsaved notes are kept. The bundle is replaced only after that process has exited; one that is still
# there after WAIT_SECONDS is killed.
WAIT_SECONDS=25
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  started=$SECONDS
  pkill -x "$APP_NAME" 2>/dev/null || true
  waited=0
  while pgrep -x "$APP_NAME" >/dev/null 2>&1 && [ "$waited" -lt $((WAIT_SECONDS * 5)) ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "WARNING: $APP_NAME did not exit ${WAIT_SECONDS} s after SIGTERM; killing it" >&2
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
  else
    echo "Stopped the running $APP_NAME after $((SECONDS - started)) s"
  fi
fi
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$SRC" "$INSTALL_DIR/$APP_NAME.app"
echo "Installed: $INSTALL_DIR/$APP_NAME.app"
