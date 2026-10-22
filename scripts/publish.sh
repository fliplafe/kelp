#!/bin/zsh
# Publish dist/Kelp.dmg (`make release`: signed + notarized) as GitHub release v<version>, with the Sparkle appcast
# the app reads (SUFeedURL: the latest release's appcast.xml). One command:  make publish
# First bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist: Sparkle compares CFBundleVersion.
# The update key is in the login keychain (generate_keys --account kelp); without it no update installs, so keep a
# backup: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account kelp -x <file>
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=https://github.com/nikiomori/kelp
key() { plutil -extract "$1" raw Resources/Info.plist; }
V=$(key CFBundleShortVersionString)
spctl -a -t open --context context:primary-signature dist/Kelp.dmg   # notarized, or Gatekeeper blocks it
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account kelp dist/Kelp.dmg)   # sparkle:edSignature="…" length="…"
cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kelp</title>
    <item>
      <title>$V</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(key CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(key LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$REPO/releases/tag/v$V</sparkle:fullReleaseNotesLink>
      <enclosure url="$REPO/releases/download/v$V/Kelp.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
git tag "v$V" && git push -q origin "v$V"   # the commit the DMG was built from
gh release create "v$V" dist/Kelp.dmg dist/appcast.xml --verify-tag --title "Kelp $V" --generate-notes
