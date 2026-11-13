#!/bin/bash
# Builds "LX Book Draw.app" (Apple Silicon + Intel) into build/ and zips it. Needs Xcode on a Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
BUILD="${GITHUB_RUN_NUMBER:-1}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

APP="build/LX Book Draw.app"
mkdir -p build
if [ -d "$APP" ]; then rm -r "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/LXBookDraw" "$APP/Contents/MacOS/LXBookDraw"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon: every size macOS wants, made from Resources/AppIcon.png
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature: enough to run on your own Mac after "Open Anyway".
codesign --force --deep --sign - "$APP"
ZIP="build/LX-Book-Draw-v$VERSION-b$BUILD.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built: $ZIP"
