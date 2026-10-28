#!/bin/bash
# Builds CarbonCC, signs it, installs it to /Applications and launches it.
# For your own Mac (development, or installing from source).
#
# Signing, in order of preference:
#   1. $SIGN_IDENTITY, if set
#   2. a "Developer ID Application" certificate in your keychain
#   3. a self-signed "CarbonCC Local Signing" certificate (created once, automatically)
# Using the same identity every time keeps the Accessibility permission across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/CarbonCC.app"
DEST="/Applications/CarbonCC.app"
LOCAL_CERT="CarbonCC Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

scripts/build.sh

IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)"
fi

if [ -n "$IDENTITY" ]; then
  echo "→ Signing with ${IDENTITY}…"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  if ! security find-certificate -c "$LOCAL_CERT" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "→ Creating a local signing certificate (one time only)…"
    TMP="$(mktemp -d)"
    cat > "$TMP/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $LOCAL_CERT
[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    # /usr/bin/openssl (LibreSSL) makes a .p12 the macOS keychain can import.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
      -name "$LOCAL_CERT" -out "$TMP/cert.p12" -passout pass:carboncc
    security import "$TMP/cert.p12" -k "$KEYCHAIN" -P carboncc -T /usr/bin/codesign >/dev/null
    rm -rf "$TMP"
  fi
  echo "→ Signing with \"$LOCAL_CERT\" (if asked for your password, choose “Always Allow”)…"
  codesign --force --sign "$LOCAL_CERT" "$APP" || {
    echo "  ! Falling back to ad-hoc signing (permission must be re-granted after each build)."
    codesign --force --sign - "$APP"
  }
fi

echo "→ Installing to /Applications…"
pkill -x CarbonCC 2>/dev/null || true
pkill -x ClipBar  2>/dev/null || true   # pre-release name
sleep 0.5
rm -rf "$DEST"
ditto "$APP" "$DEST"
touch "$DEST"

open "$DEST"
echo
echo "✓ CarbonCC is running (menu bar)."
echo "  If auto-paste doesn't work: System Settings → Privacy & Security → Accessibility"
echo "  → remove CarbonCC with “–”, add it again and turn it on. Needed once per signing identity."
