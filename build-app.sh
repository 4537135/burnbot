#!/bin/zsh
# Builds Burnbot.app in this folder: a native Mac app with the tracker inside it.
# Needs Xcode's Swift compiler and Node.js. Run it again after changing any code.
set -euo pipefail
cd "$(dirname "$0")"

APP="Burnbot.app"
BUILD="build"

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/server" "$BUILD"

echo "Compiling the app…"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/Burnbot" app/main.swift -framework Cocoa -framework WebKit

echo "Packing the tracker…"
cp app/Info.plist "$APP/Contents/Info.plist"
cp -R server.mjs package.json lib public "$APP/Contents/Resources/server/"
# Where Node lives on this Mac, so the app finds it without a terminal's PATH.
command -v node > "$APP/Contents/Resources/node-path"

echo "Drawing the icon…"
node tools/make-icon.mjs "$BUILD/Burnbot.iconset"
iconutil -c icns "$BUILD/Burnbot.iconset" -o "$APP/Contents/Resources/Burnbot.icns"

# Sign it for this Mac only, so macOS treats the bundle as one unit.
codesign --force --deep --sign - "$APP" 2>/dev/null

rm -rf "$BUILD"
echo "Built $APP. Open it, or drag it to Applications."
