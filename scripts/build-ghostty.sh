#!/bin/zsh
# Build libghostty (GhosttyKit.xcframework) into Vendor/ — the terminal backend from the plan.
# Needs zig 0.16 exactly (Ghostty checks major.minor); it is downloaded into a cache, nothing is installed system-wide.
set -euo pipefail
cd "$(dirname "$0")/.."
GHOSTTY_COMMIT=${GHOSTTY_COMMIT:-189af86eac5e91e1b282bdaf371f369c3863591f}
ZIG_VERSION=0.16.0
CACHE="$HOME/Library/Caches/kelp-build"
ARCH=$(uname -m | sed 's/arm64/aarch64/')
ZIG="$CACHE/zig-$ARCH-macos-$ZIG_VERSION/zig"
mkdir -p "$CACHE"
if [ ! -x "$ZIG" ]; then
  curl -sSfL "https://ziglang.org/download/$ZIG_VERSION/zig-$ARCH-macos-$ZIG_VERSION.tar.xz" | tar xJ -C "$CACHE"
fi
SRC="$CACHE/ghostty"
if [ ! -d "$SRC/.git" ]; then git clone -q https://github.com/ghostty-org/ghostty "$SRC"; fi
git -C "$SRC" fetch -q --depth 1 origin "$GHOSTTY_COMMIT" 2>/dev/null || git -C "$SRC" fetch -q origin
git -C "$SRC" checkout -q "$GHOSTTY_COMMIT"
(cd "$SRC" && "$ZIG" build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=universal -Doptimize=ReleaseFast)
rm -rf Vendor/GhosttyKit.xcframework; mkdir -p Vendor   # a fresh clone has no Vendor/ (gitignored)
cp -R "$SRC/macos/GhosttyKit.xcframework" Vendor/
cp "$SRC/LICENSE" Vendor/GhosttyKit.xcframework/   # for the app's credits (scripts/bundle.sh)
for h in Vendor/GhosttyKit.xcframework/*/Headers; do cp "$SRC/include/module.modulemap" "$h/"; done
echo "built Vendor/GhosttyKit.xcframework (ghostty $GHOSTTY_COMMIT)"
