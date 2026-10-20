#!/bin/zsh
# Kelp's translations (Resources/Localizable.xcstrings, a String Catalog).
#   scripts/strings.sh sync              add the strings the code uses now (a build that emits them; slow, run when text changes)
#   scripts/strings.sh install <dir>     compile the catalog into <dir> (an app's Contents/Resources, or .build/debug)
set -euo pipefail
cd "$(dirname "$0")/.."
CAT=Resources/Localizable.xcstrings
case "${1:-}" in
  sync)
    OUT=$(mktemp -d)
    swift build --product KelpApp --scratch-path .build/strings -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
    xcrun xcstringstool sync "$CAT" --stringsdata "$OUT"/*.stringsdata
    echo "Synced; new strings need translations in $CAT" ;;
  install)
    DIR=${2:?usage: strings.sh install <dir>}
    xcrun xcstringstool compile "$CAT" --output-directory "$DIR"
    mkdir -p "$DIR/en.lproj"   # English is the text in the code; the folder says Kelp speaks it
    [ -f "$DIR/en.lproj/Localizable.strings" ] || echo '/* English: the keys */' > "$DIR/en.lproj/Localizable.strings" ;;
  *) echo "usage: scripts/strings.sh sync | install <dir>"; exit 2 ;;
esac
