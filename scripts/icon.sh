#!/bin/zsh
# Resources/AppIcon.svg → Resources/AppIcon.icns. Renders with Chrome (headless) for a transparent background.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); SET=$T/AppIcon.iconset; mkdir "$SET"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --default-background-color=00000000 --window-size=1024,1024 --screenshot="$T/1024.png" "file://$PWD/Resources/AppIcon.svg" 2>/dev/null
for s in 16 32 128 256 512; do
  sips -z $s $s "$T/1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$T/1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
