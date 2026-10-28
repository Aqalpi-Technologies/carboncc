#!/bin/bash
# Writes Casks/carboncc.rb in the Homebrew tap repo for the current release and pushes it.
# Used by the release workflow. Needs VERSION and TAP_TOKEN (write access to the tap repo).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?VERSION is required}"
: "${TAP_TOKEN:?TAP_TOKEN is required}"
OWNER="Aqalpi-Technologies"
ZIP="build/CarbonCC-$VERSION.zip"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
TAP_DIR="build/homebrew-tap"

git clone "https://x-access-token:${TAP_TOKEN}@github.com/$OWNER/homebrew-tap.git" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$SHA256/g" \
  packaging/carboncc.rb.template > "$TAP_DIR/Casks/carboncc.rb"
[ -f "$TAP_DIR/README.md" ] || cp packaging/tap-README.md "$TAP_DIR/README.md"

cd "$TAP_DIR"
git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/carboncc.rb README.md
if git diff --cached --quiet; then
  echo "Tap already up to date."
  exit 0
fi
git commit -m "carboncc $VERSION"
git push origin HEAD:main
echo "✓ Homebrew tap updated to $VERSION"
