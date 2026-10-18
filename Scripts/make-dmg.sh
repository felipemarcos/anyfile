#!/bin/zsh
# Packages an app into a compressed disk image with a drag-to-Applications layout.
# Usage: Scripts/make-dmg.sh path/to/AnyFile.app output.dmg [volume name]
set -euo pipefail

APP="${1:?usage: make-dmg.sh App.app out.dmg [volume name]}"
OUT="${2:?usage: make-dmg.sh App.app out.dmg [volume name]}"
VOLNAME="${3:-${APP:t:r}}"
ROOT="${0:A:h:h}"
ASSETS="$ROOT/Scripts/dmg"

WORK="$(mktemp -d)"
MOUNT="$WORK/mnt"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Retina background: combine 1x and 2x into one multi-resolution TIFF.
tiffutil -cathidpicheck "$ASSETS/background.png" "$ASSETS/background@2x.png" -out "$WORK/background.tiff" >/dev/null

APP_MB=$(( $(du -sm "$APP" | cut -f1) + 40 ))
hdiutil create -quiet -size "${APP_MB}m" -fs HFS+ -volname "$VOLNAME" -layout NONE "$WORK/rw.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/rw.dmg"

ditto "$APP" "$MOUNT/${APP:t}"
ln -s /Applications "$MOUNT/Applications"
mkdir "$MOUNT/.background"
cp "$WORK/background.tiff" "$MOUNT/.background/background.tiff"

# Finder lays out the window and stores it in the volume's .DS_Store.
# Skipped (with a warning) where Finder can't be scripted, e.g. a locked CI session.
if ! osascript <<EOF
tell application "Finder"
  set dmg to POSIX file "$MOUNT" as alias
  open dmg
  set w to container window of dmg
  set current view of w to icon view
  set toolbar visible of w to false
  set statusbar visible of w to false
  set bounds of w to {200, 120, 860, 548}
  set opts to icon view options of w
  set arrangement of opts to not arranged
  set icon size of opts to 112
  set text size of opts to 13
  set background picture of opts to file ".background:background.tiff" of dmg
  set position of item "${APP:t}" of dmg to {170, 190}
  set position of item "Applications" of dmg to {490, 190}
  update dmg without registering applications
  delay 1
  close w
end tell
EOF
then
  echo "warning: Finder layout failed; the disk image will use a plain window" >&2
fi

chflags hidden "$MOUNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true

mkdir -p "${OUT:h}"
rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format ULFO -o "$OUT"
echo "Created $OUT"
