#!/bin/zsh
# Builds MuPDF's `mutool` from the official source release into Vendor/mutool, for PDF/AI → SVG.
# MuPDF vendors its third-party libraries, so the result only links against macOS itself.
# License: AGPL-3.0 (https://mupdf.com). Pinned version + SHA-256.
set -euo pipefail

VERSION="1.28.5"
URL="https://mupdf.com/downloads/archive/mupdf-${VERSION}-source.tar.gz"
SHA256="98a5c10cda20c3992cdf76ff6b2a1149c32bd79cc796d3f703230b1185b7e934"

ROOT="${0:A:h:h}"
DEST="$ROOT/Vendor/mutool"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading MuPDF $VERSION source…"
curl -fL --progress-bar -o "$WORK/mupdf.tar.gz" "$URL"
ACTUAL="$(shasum -a 256 "$WORK/mupdf.tar.gz" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
  echo "error: checksum mismatch (expected $SHA256, got $ACTUAL)" >&2
  exit 1
fi

tar -xzf "$WORK/mupdf.tar.gz" -C "$WORK"
cd "$WORK/mupdf-${VERSION}-source"

echo "Building mutool (a few minutes)…"
# No viewer, JavaScript, OCR or OpenSSL (signatures): just a self-contained converter.
make -j"$(sysctl -n hw.ncpu)" build=release \
  HAVE_X11=no HAVE_GLUT=no HAVE_WAYLAND=no HAVE_LEPTONICA=no HAVE_TESSERACT=no HAVE_LIBCRYPTO=no \
  XCFLAGS="-DFZ_ENABLE_JS=0 -mmacosx-version-min=14.0" XLIBS="-mmacosx-version-min=14.0" \
  tools >/dev/null

# The app ships this binary, so it must not depend on Homebrew or other local libraries.
FOREIGN=$(otool -L build/release/mutool | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib|/System)/' || true)
[[ -z "$FOREIGN" ]] || { echo "error: mutool links non-system libraries:\n$FOREIGN" >&2; exit 1; }

mkdir -p "$ROOT/Vendor"
cp -f build/release/mutool "$DEST"
strip -x "$DEST"
chmod +x "$DEST"
"$DEST" -v 2>&1 | head -1
echo "Installed $DEST"
