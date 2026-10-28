#!/bin/bash
# Compiles CarbonCC into build/CarbonCC.app (universal: Apple Silicon + Intel).
# Does not sign — use scripts/install.sh (local) or scripts/release.sh (distribution).
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="CarbonCC"
BUNDLE_ID="com.aqalpi.carboncc"
MIN_MACOS="13.0"
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/$APP_NAME.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compiling $APP_NAME $VERSION (build $BUILD_NUMBER)…"
for arch in arm64 x86_64; do
  swiftc -O Sources/CarbonCC/*.swift \
    -target "$arch-apple-macos$MIN_MACOS" \
    -o "build/$APP_NAME-$arch"
done
lipo -create "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64" \
  -output "$APP/Contents/MacOS/$APP_NAME"
rm -f "build/$APP_NAME-arm64" "build/$APP_NAME-x86_64"

# App icon: Resources/AppIcon.png (square, 1024×1024, rounded shape with transparent corners)
ICON_KEY=""
if [ -f Resources/AppIcon.png ]; then
  echo "→ Building app icon…"
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    d=$((s * 2))
    sips -s format png -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
    sips -s format png -z $d $d Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "  (no Resources/AppIcon.png — building without an app icon)"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>               <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>        <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>$VERSION</string>
  <key>CFBundleVersion</key>            <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>     <string>$MIN_MACOS</string>
  <key>LSUIElement</key>                <true/>
  <key>LSApplicationCategoryType</key>  <string>public.app-category.productivity</string>
  <key>NSHumanReadableCopyright</key>   <string>Copyright © 2026 Aqalpi Technologies. MIT License.</string>
  $ICON_KEY
</dict>
</plist>
PLIST

echo "✓ Built $APP"
