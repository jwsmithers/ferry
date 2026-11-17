#!/bin/bash
# Builds Ferry.app into ./build. Run `./build.sh install` to also copy it to Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Ferry.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Ferry "$APP/Contents/MacOS/Ferry"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f Resources/Ferry.icns ]; then
  swift scripts/make_icon.swift Resources/Ferry.icns
fi
cp Resources/Ferry.icns "$APP/Contents/Resources/Ferry.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  rm -rf "$DEST/Ferry.app"
  cp -R "$APP" "$DEST/"
  echo "Installed to $DEST/Ferry.app"
fi
