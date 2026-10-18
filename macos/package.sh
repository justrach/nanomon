#!/bin/sh
# Builds nanomon.app and nanomon-macos-arm64.dmg in zig-out/package.
#
#   VERSION=0.1.0 sh macos/package.sh
#
# Signs with $CODESIGN_IDENTITY (a "Developer ID Application" identity in
# the keychain) when it is set, else ad hoc. Notarizes and staples the app
# and the disk image when NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID
# (an App Store Connect API key) are set too.
set -eu
cd "$(dirname "$0")/.."

app=nanomon
version="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 0.0.0)}"
version="${version#v}"
out=zig-out/package
bundle="$out/$app.app"
dmg="$out/$app-macos-arm64.dmg"

zig build -Doptimize=ReleaseFast ${ZIG_FLAGS:-}
rm -rf "$out"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "zig-out/bin/$app" "$bundle/Contents/MacOS/$app"
cp macos/AppIcon.icns "$bundle/Contents/Resources/AppIcon.icns"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>$app</string>
  <key>CFBundleIdentifier</key><string>com.justrach.$app</string>
  <key>CFBundleExecutable</key><string>$app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleGetInfoString</key><string>A small, smooth activity monitor</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

sign() {
  if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$1"
  else
    codesign --force --sign - "$1"
  fi
}

notarize() {
  [ -n "${CODESIGN_IDENTITY:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ] || return 0
  xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID" --wait
}

sign "$bundle"
if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${CODESIGN_IDENTITY:-}" ]; then
  ditto -c -k --keepParent "$bundle" "$out/$app.zip"
  notarize "$out/$app.zip"
  xcrun stapler staple "$bundle"
  rm "$out/$app.zip"
fi

# The disk image: the app, and Applications to drag it to.
stage="$out/dmg"
mkdir -p "$stage"
cp -R "$bundle" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$app" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg"
rm -rf "$stage"
sign "$dmg"
if [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${CODESIGN_IDENTITY:-}" ]; then
  notarize "$dmg"
  xcrun stapler staple "$dmg"
fi
shasum -a 256 "$dmg" | tee "$dmg.sha256"
