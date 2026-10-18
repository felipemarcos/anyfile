#!/bin/zsh
# Downloads a static arm64 ffmpeg build into Vendor/ffmpeg so the Xcode build can bundle it.
# Source: https://ffmpeg.martin-riedl.de (static builds, GPL). Pinned version + SHA-256.
set -euo pipefail

VERSION_PATH="1789931890_9.0.2"
URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/${VERSION_PATH}/ffmpeg.zip"
SHA256="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"

ROOT="${0:A:h:h}"
DEST="$ROOT/Vendor/ffmpeg"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading ffmpeg ${VERSION_PATH#*_}…"
curl -fL --progress-bar -o "$WORK/ffmpeg.zip" "$URL"

ACTUAL="$(shasum -a 256 "$WORK/ffmpeg.zip" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "error: checksum mismatch (expected $SHA256, got $ACTUAL)" >&2
  exit 1
fi

mkdir -p "$WORK/out"
ditto -x -k "$WORK/ffmpeg.zip" "$WORK/out"
BIN="$(find "$WORK/out" -type f -name ffmpeg -perm -u+x | head -1)"
[[ -n "$BIN" ]] || { echo "error: no ffmpeg binary in archive" >&2; exit 1; }

mkdir -p "$ROOT/Vendor"
mv -f "$BIN" "$DEST"
chmod +x "$DEST"
xattr -c "$DEST" 2>/dev/null || true
"$DEST" -hide_banner -version | head -1
echo "Installed $DEST"
