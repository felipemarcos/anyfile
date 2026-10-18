#!/bin/zsh
# Builds a release: Release-configuration app with bundled ffmpeg, a drag-to-Applications
# DMG, and a Sparkle appcast signed with the EdDSA update key.
#
# Usage: Scripts/build-release.sh <version> [build-number] [release-notes.md]
#   version       e.g. 1.2.0 (becomes CFBundleShortVersionString)
#   build-number  monotonically increasing CFBundleVersion; defaults to the commit count
#   release-notes Markdown bullet list embedded in the update dialog (optional)
#
# Signing key: $SPARKLE_PRIVATE_KEY if set (CI), else the "anyfile" key in the login keychain.
# Output: dist/AnyFile-<version>.dmg and dist/appcast.xml
set -euo pipefail

VERSION="${1:?usage: build-release.sh <version> [build-number] [release-notes.md]}"
BUILD="${2:-$(git rev-list --count HEAD)}"
NOTES="${3:-}"
REPO="felipemarcos/anyfile"

[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "error: version must look like 1.2.3" >&2; exit 1; }

ROOT="${0:A:h:h}"
cd "$ROOT"
DERIVED="$ROOT/build/release"
DIST="$ROOT/dist"

[[ -x Vendor/ffmpeg ]] || Scripts/fetch-ffmpeg.sh

echo "Building AnyFile $VERSION ($BUILD)…"
xcodebuild -project AnyFile.xcodeproj -scheme AnyFile -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  clean build -quiet

APP="$DERIVED/Build/Products/Release/AnyFile.app"
codesign --verify --deep --strict "$APP"
[[ -x "$APP/Contents/Resources/ffmpeg" ]] || { echo "error: ffmpeg missing from the app" >&2; exit 1; }
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$PLIST_VERSION" == "$VERSION" ]] || { echo "error: built version $PLIST_VERSION != $VERSION" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
DMG="$DIST/AnyFile-$VERSION.dmg"
Scripts/make-dmg.sh "$APP" "$DMG" "AnyFile $VERSION"

# Release notes shown in Sparkle's update window: an HTML file named like the archive.
if [[ -n "$NOTES" && -s "$NOTES" ]]; then
  {
    echo '<!DOCTYPE html><html><head><meta charset="utf-8"><style>body{font:13px -apple-system,sans-serif}</style></head><body>'
    echo "<h3>AnyFile $VERSION</h3><ul>"
    sed -n 's/^[-*] \(.*\)$/\1/p' "$NOTES" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/^/<li>/; s/$/<\/li>/'
    echo "</ul></body></html>"
  } > "$DIST/AnyFile-$VERSION.html"
fi

SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST_ARGS=(
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/"
  --link "https://github.com/$REPO"
  --embed-release-notes
  -o "$DIST/appcast.xml"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  print -rn -- "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${APPCAST_ARGS[@]}" "$DIST"
else
  "$SPARKLE_BIN/generate_appcast" --account anyfile "${APPCAST_ARGS[@]}" "$DIST"
fi
rm -f "$DIST/AnyFile-$VERSION.html"

grep -q 'sparkle:edSignature' "$DIST/appcast.xml" || { echo "error: appcast is not signed" >&2; exit 1; }
echo "Release artifacts:"
/bin/ls -lh "$DIST"
