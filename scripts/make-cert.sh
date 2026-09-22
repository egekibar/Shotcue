#!/bin/bash
# Creates a self-signed code-signing certificate "Shotcue Dev" so TCC grants survive rebuilds.
# Safe to re-run: when a certificate with that name already exists it only reports its state.
set -euo pipefail
NAME="${1:-Shotcue Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

trust_steps() {
  echo "Set the trust manually: Keychain Access → login → Certificates → \"$NAME\" → Get Info → Trust →" >&2
  echo "  Code Signing: Always Trust, then close the window and enter your password." >&2
}
identity_line() { security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$NAME\""; }

# Never create a second one: a duplicate name makes `codesign --sign "$NAME"` ambiguous, and a new
# certificate changes the app's designated requirement, so existing TCC grants stop matching.
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists; not creating another one."
  if identity_line >/dev/null; then
    echo "Certificate ready: $NAME"
  else
    echo "It is not valid for code signing yet." >&2
    trust_steps
  fi
  echo "To recreate it: Keychain Access → login → My Certificates → delete \"$NAME\" and its private key,"
  echo "then run this script again (Screen Recording and Microphone must then be granted again)."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT # the unencrypted key and the .p12 never outlive the script, even on failure
cd "$WORK"
openssl req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout dev.key -out dev.crt \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=codeSigning"
LEGACY=""; openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -in dev.crt -inkey dev.key -out dev.p12 -password pass:shotcue
security import dev.p12 -k "$KEYCHAIN" -P shotcue -T /usr/bin/codesign
# Trust for code signing (may show a system password prompt).
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" dev.crt; then
  echo "Could not set the code-signing trust automatically." >&2
  trust_steps
  exit 1
fi
if identity_line; then
  echo "Certificate ready: $NAME"
else
  echo "\"$NAME\" was imported but is not valid for code signing yet." >&2
  trust_steps
  exit 1
fi
