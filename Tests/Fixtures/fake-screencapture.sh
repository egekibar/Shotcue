#!/bin/bash
# Fake /usr/sbin/screencapture. The last argument is the output path.
#   FAKE_SCREENCAPTURE_SCENARIO  success (default) | cancel | error
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${@: -1}"
case "${FAKE_SCREENCAPTURE_SCENARIO:-success}" in
  success) cp "$DIR/sample.png" "$OUT" ;;
  cancel)  exit 1 ;;                                  # real screencapture: ESC → exit 1, empty stderr
  error)   echo "screencapture: could not create image" >&2; exit 2 ;;
esac
