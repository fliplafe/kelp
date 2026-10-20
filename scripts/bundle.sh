#!/bin/zsh
# Build dist/Kelp.app (+ DMG). One command:  scripts/bundle.sh
# Signing/notarization are opt-in via env:
#   SIGN_ID="Developer ID Application: Name (TEAM)"   sign app + dmg
#   NOTARY_PROFILE=kelp                               notarytool keychain profile (xcrun notarytool store-credentials)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
# The terminal renders with libghostty (universal static lib, built once into Vendor/).
[ -d Vendor/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN=$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)
APP=dist/Kelp.app
rm -rf "$APP" dist/Kelp.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/KelpApp" "$APP/Contents/MacOS/KelpApp"
cp "$BIN/kelpd" "$BIN/kelp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # from AppIcon.svg: scripts/icon.sh
[ -d "$BIN/Sparkle.framework" ] && cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/" || true
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
scripts/strings.sh install "$APP/Contents/Resources"   # English and Russian
if [ -n "${SIGN_ID:-}" ]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_ID")
  # Sparkle ships its helpers ad-hoc signed; notarization needs every nested binary signed by us, inside out.
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [ -d "$SP" ]; then
    "${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
    "${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$SP/Autoupdate"
    "${SIGN[@]}" "$SP/Updater.app"
    "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  "${SIGN[@]}" "$APP/Contents/MacOS/kelpd"
  "${SIGN[@]}" "$APP/Contents/MacOS/kelp"
  codesign --force --options runtime --timestamp --entitlements Resources/Kelp.entitlements --sign "$SIGN_ID" "$APP"
fi
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Kelp -srcfolder "$STAGE" -ov -format UDZO dist/Kelp.dmg
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" dist/Kelp.dmg
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    OUT=$(xcrun notarytool submit dist/Kelp.dmg --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    ID=$(print -r -- "$OUT" | plutil -extract id raw -o - -)
    STATUS=$(print -r -- "$OUT" | plutil -extract status raw -o - -)
    echo "notarization $ID: $STATUS"
    if [ "$STATUS" != "Accepted" ]; then
      xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE"   # Apple's reasons, per file
      exit 1
    fi
    xcrun stapler staple dist/Kelp.dmg
    spctl -a -t open --context context:primary-signature -v dist/Kelp.dmg
  fi
fi
echo "built dist/Kelp.dmg"
