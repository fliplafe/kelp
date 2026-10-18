#!/bin/zsh
# Build dist/Krill.app (+ DMG). One command:  scripts/bundle.sh
# Signing/notarization are opt-in via env:
#   SIGN_ID="Developer ID Application: Name (TEAM)"   sign app + dmg
#   NOTARY_PROFILE=krill                              notarytool keychain profile (xcrun notarytool store-credentials)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
export KRILL_NO_GHOSTTY=1   # the libghostty probe isn't part of the app (and its library is arm64-only)
swift build -c "$CONFIG" --arch arm64 --arch x86_64
BIN=$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)
APP=dist/Krill.app
rm -rf "$APP" dist/Krill.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/KrillApp" "$APP/Contents/MacOS/KrillApp"
cp "$BIN/krilld" "$BIN/krill" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -d "$BIN/Sparkle.framework" ] && cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/" || true
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
if [ -n "${SIGN_ID:-}" ]; then
  for f in "$APP"/Contents/Frameworks/*.framework(N) "$APP"/Contents/MacOS/krilld "$APP"/Contents/MacOS/krill; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$f"
  done
  codesign --force --options runtime --timestamp --entitlements Resources/Krill.entitlements --sign "$SIGN_ID" "$APP"
fi
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Krill -srcfolder "$STAGE" -ov -format UDZO dist/Krill.dmg
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" dist/Krill.dmg
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit dist/Krill.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple dist/Krill.dmg
  fi
fi
echo "built dist/Krill.dmg"
