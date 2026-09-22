#!/bin/bash
# Copies dist/<App>.app to ~/Applications (stable path keeps TCC grants), restarting a running instance.
set -euo pipefail
APP_NAME="${1:-Shotcue}"
INSTALL_DIR="${2:-$HOME/Applications}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/$APP_NAME.app"
[ -d "$SRC" ] || { echo "dist/$APP_NAME.app missing; run make bundle" >&2; exit 1; }
mkdir -p "$INSTALL_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$SRC" "$INSTALL_DIR/$APP_NAME.app"
echo "Installed: $INSTALL_DIR/$APP_NAME.app"
