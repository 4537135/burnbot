#!/bin/zsh
# Builds Burnbot.app in this folder, and a zip of it in dist/ for people to
# download. The app is self-contained: it runs on Apple Silicon and Intel Macs
# (macOS 13 or newer) with nothing else installed.
#
# Needs Xcode's Swift compiler. Run it again after changing any code.
#
#   ./build-app.sh
#
# To hand the app to other people without macOS warning them, it has to be
# signed with a Developer ID and notarized by Apple. With a "Developer ID
# Application" certificate in the keychain this signs with it; add
#   NOTARY_PROFILE=<name>   (made once with: xcrun notarytool store-credentials <name>)
# to notarize as well. Without them the app is signed for this Mac only.
set -euo pipefail
cd "$(dirname "$0")"

APP="Burnbot.app"
BUILD="build"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD" dist

echo "Compiling for Apple Silicon and Intel…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -o "$BUILD/Burnbot-$arch" app/*.swift \
    -framework Cocoa -framework WebKit -framework ServiceManagement
done
lipo -create "$BUILD/Burnbot-arm64" "$BUILD/Burnbot-x86_64" -output "$APP/Contents/MacOS/Burnbot"

echo "Packing the screens…"
cp app/Info.plist "$APP/Contents/Info.plist"
cp -R public "$APP/Contents/Resources/public"
cp -R tools/fixtures/demo "$APP/Contents/Resources/demo"   # Play Every Moment
rm -f "$APP/Contents/Resources/demo/expected.txt" "$APP/Contents/Resources/demo/README.txt"

# The icon is drawn from the same robot as the screens. Redrawing it needs
# Node.js; without it the icon already in app/ is used.
if command -v node >/dev/null; then
  node tools/make-icon.mjs "$BUILD/Burnbot.iconset" >/dev/null
  iconutil -c icns "$BUILD/Burnbot.iconset" -o app/Burnbot.icns
fi
cp app/Burnbot.icns "$APP/Contents/Resources/Burnbot.icns"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing as $IDENTITY…"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "No Developer ID certificate found: signing for this Mac only."
  codesign --force --sign - "$APP"
fi

ZIP="dist/Burnbot-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ -n "$IDENTITY" && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Sending to Apple for notarization…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

rm -rf "$BUILD"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Burnbot")) and $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))."
