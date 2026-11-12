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

# Ad-hoc signature: enough to run on your own Mac after "Open Anyway".
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" "build/LX Book Draw v$VERSION.zip"
echo "Built: build/LX Book Draw v$VERSION.zip"
