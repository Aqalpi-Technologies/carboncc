#!/bin/bash
# Builds a signed, notarized and stapled build/CarbonCC-<version>.zip for distribution.
#
# Needs:
#   • a "Developer ID Application" certificate in the keychain (or $SIGN_IDENTITY)
#   • notarization credentials, either:
#       NOTARY_PROFILE=<name>                          (local: from `xcrun notarytool store-credentials`)
#     or
#       NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID  (App Store Connect API key — used in CI)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
APP="build/CarbonCC.app"
ZIP="build/CarbonCC-$VERSION.zip"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [ -z "$IDENTITY" ]; then
  echo "✗ No \"Developer ID Application\" certificate found in the keychain." >&2
  exit 1
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  echo "✗ No notarization credentials. Set NOTARY_PROFILE, or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID." >&2
  exit 1
fi

scripts/build.sh

echo "→ Signing with $IDENTITY (hardened runtime)…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "→ Submitting to Apple for notarization (usually 1–5 minutes)…"
ditto -c -k --keepParent "$APP" build/notarize.zip
RESULT="$(xcrun notarytool submit build/notarize.zip "${NOTARY_ARGS[@]}" --wait --output-format json)"
rm -f build/notarize.zip
STATUS="$(plutil -extract status raw -o - - <<< "$RESULT")"
SUBMISSION_ID="$(plutil -extract id raw -o - - <<< "$RESULT")"
echo "  Notarization status: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  echo "✗ Notarization failed. Apple's log:" >&2
  xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 || true
  exit 1
fi

echo "→ Stapling the notarization ticket…"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✓ $ZIP is ready to publish."
