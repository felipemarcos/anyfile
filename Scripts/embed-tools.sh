#!/bin/zsh
# Xcode build phase: copies the vendored command-line tools into the app's Resources and signs them.
# Missing tools are skipped with a warning; the app then falls back to Homebrew copies at runtime.
DEST="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
for TOOL in ffmpeg mutool; do
  SRC="${PROJECT_DIR}/Vendor/$TOOL"
  if [ -x "$SRC" ]; then
    cp -f "$SRC" "$DEST/$TOOL"
    codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$DEST/$TOOL"
  else
    echo "warning: Vendor/$TOOL missing; run Scripts/fetch-$([ $TOOL = mutool ] && echo mupdf || echo $TOOL).sh to bundle it"
    rm -f "$DEST/$TOOL"
  fi
done
