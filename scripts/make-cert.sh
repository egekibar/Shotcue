#!/bin/bash
# Creates a self-signed code-signing certificate "Shotcue Dev" so TCC grants survive rebuilds.
set -euo pipefail
NAME="${1:-Shotcue Dev}"
WORK="$(mktemp -d)"
cd "$WORK"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout dev.key -out dev.crt \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=codeSigning"
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -in dev.crt -inkey dev.key -out dev.p12 -password pass:shotcue
security import dev.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P shotcue -T /usr/bin/codesign
# Trust for code signing (may show a system prompt). If it fails, do it manually:
# Keychain Access → login → Certificates → "Shotcue Dev" → Get Info → Trust → Code Signing: Always Trust.
security add-trusted-cert -r trustRoot -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" dev.crt || \
  echo "Set trust manually in Keychain Access (see comment above)." >&2
rm -rf "$WORK"
security find-identity -v -p codesigning | grep "$NAME" && echo "Certificate ready: $NAME"
