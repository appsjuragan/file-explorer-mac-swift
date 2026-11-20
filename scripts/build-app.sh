#!/bin/sh
# Build "File Explorer.app" (universal arm64 + x86_64) from the Swift package.
#
#   scripts/build-app.sh                 ad-hoc signed app in dist/
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#   NOTARIZE=1 (+ APPLE_API_KEY, APPLE_API_KEY_ID, APPLE_API_ISSUER from .env.signing)
#
# Requires Xcode command line tools (Swift 5.9+). Secrets are read from the
# environment / .env.signing and are never printed.
set -eu
cd "$(dirname "$0")/.."

# Prefer CommandLineTools to match macOS 15.5 SDK swiftmodules
if [ -d "/Library/Developer/CommandLineTools" ]; then
  export DEVELOPER_DIR="/Library/Developer/CommandLineTools"
fi

APP_NAME="File Explorer"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
OUT="dist"
APP="$OUT/$APP_NAME.app"

if [ -f .env.signing ]; then
  set -a; . ./.env.signing; set +a
fi

echo "==> Building universal release binary"
swift build -c release --arch arm64
swift build -c release --arch x86_64
mkdir -p "$OUT"
BIN="$OUT/FileExplorer-bin"
lipo -create -output "$BIN" \
  "$(swift build -c release --arch arm64 --show-bin-path)/FileExplorer" \
  "$(swift build -c release --arch x86_64 --show-bin-path)/FileExplorer"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FileExplorer"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -f build/icon.png ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" build/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" build/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - --entitlements Resources/FileExplorer.entitlements "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" \
    --entitlements Resources/FileExplorer.entitlements "$APP"
fi
codesign --verify --strict "$APP"

ZIP="$OUT/File-Explorer-$VERSION-universal.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ "${NOTARIZE:-0}" = "1" ] && [ "$IDENTITY" != "-" ]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$ZIP" --key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "==> Done: $APP"
echo "    $ZIP"
