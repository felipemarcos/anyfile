# AnyFile

A SwiftUI macOS app that converts files locally. Nothing is uploaded.

Drop files on the window (or the Dock icon, or use **Open With → AnyFile**), pick a target format per file or with **Set All To**, and press **Convert** (⌘↩). Select files and press Delete to remove them from the list. Output goes next to the original, or to a folder chosen in Settings. Existing files are never overwritten.

| Input | Output | Engine |
|---|---|---|
| PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP | PNG, JPEG, HEIC, TIFF, GIF, BMP, PDF (+ WebP via ffmpeg) | ImageIO |
| MOV, MP4, M4V | MP4, MOV, M4V, M4A | AVFoundation |
| M4A, WAV, AIFF, CAF, MP3, AAC | M4A, WAV, AIFF, CAF | AVFoundation |
| Video incl. WebM, MKV, AVI, GIF | MP4, MOV, WebM, MKV, AVI, GIF, WebP, MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus | ffmpeg |
| Audio incl. FLAC, OGG, Opus | MP3, M4A, AAC, WAV, AIFF, CAF, FLAC, OGG, Opus | ffmpeg |
| TXT, RTF, DOCX, HTML, ODT, Markdown | TXT, RTF, DOCX, HTML, ODT, PDF | NSAttributedString |
| PDF | PNG, JPEG, TIFF (one file per page), TXT | PDFKit |
| PDF, Illustrator (.ai) | SVG (one per page, text as outlines, optimized with SVGO) | MuPDF + SVGO |
| PDF, Illustrator (.ai) | HTML (one file, page layout kept, images embedded) | MuPDF |
| Illustrator (.ai) | PDF, PNG, JPEG, TIFF, TXT | PDFKit |
| SVG | PNG, JPEG, HEIC, TIFF, GIF, BMP, PDF (vector) | macOS (CoreSVG) |
| CSV ↔ JSON ↔ Excel (XLSX), JSON ↔ plist | | built in (+ ZIPFoundation) |

**Settings → Images → Render resolution** sets how many pixels PDF pages, Illustrator files and SVGs get when they become PNG/JPEG/HEIC/TIFF/GIF/BMP: 72, 144 (default), 216, 288, 300 or 600 dpi. The DPI is stored in the image, so prints keep the original size. Generated SVGs go through [SVGO](https://github.com/svg/svgo) 4.1.0, the engine behind SVGOMG, with SVGOMG's defaults (default preset, multipass, 3-digit precision). It runs locally in JavaScriptCore from the unmodified browser build in `AnyFile/Resources`; turn it off in Settings. PDF → HTML keeps each page's layout (positioned text, colors, embedded images) rather than producing reflowable text; bold and italic are restored from MuPDF's structured text, since its HTML writer drops them. Illustrator files need Illustrator's default "Create PDF Compatible File" option; older PostScript-based .ai files are rejected with an explanation.

Data notes: JSON key order becomes column order; CSV columns are typed only when every value converts losslessly (so `01234` stays a string); Excel dates become ISO 8601 strings; legacy `.xls` isn't supported.

## Build

Requires Xcode 27 and macOS 14+.

```sh
Scripts/fetch-ffmpeg.sh   # optional: bundle a static ffmpeg (~28 MB download)
Scripts/fetch-mupdf.sh    # optional: build MuPDF's mutool for SVG (~70 MB source, ~1 min)
xcodebuild -project AnyFile.xcodeproj -scheme AnyFile -destination 'platform=macOS' build test
```

`Scripts/fetch-ffmpeg.sh` puts a static ffmpeg in `Vendor/ffmpeg` (gitignored), and the build copies and signs it into the app. In **Settings → ffmpeg** you can stay on **Automatic** (bundled, then Homebrew/MacPorts) or choose a custom ffmpeg executable; Settings shows the version in use. With no working ffmpeg, the ffmpeg-only formats are hidden.

The app icon is drawn by `swift Scripts/make-icon.swift`, which regenerates `AnyFile/Assets.xcassets/AppIcon.appiconset`.

The project uses Xcode's classic `project.pbxproj` file; once on Xcode 27.2+, switch to the JSON `project.xcproj` format with:

```sh
xcodebuild -project AnyFile.xcodeproj -convert-project "Xcode Project"
```

## Releasing

```sh
Scripts/release.sh 1.1.0 "Short summary"
```

This tags the current commit `v1.1.0` and pushes it. The **Release** workflow (`.github/workflows/release.yml`) then runs the tests, builds a Release app with the bundled ffmpeg, packages `AnyFile-1.1.0.dmg` (drag-to-Applications window), signs a Sparkle `appcast.xml`, and publishes both to a GitHub release with notes generated from the commits since the previous tag. The build number is the commit count, so it always increases.

Installed copies find new versions through **AnyFile → Check for Updates…** (and automatic daily checks), reading `https://github.com/felipemarcos/anyfile/releases/latest/download/appcast.xml`. Updates are verified with an EdDSA key: the public half is `SUPublicEDKey` in `AnyFile-Info.plist`, the private half is in the login keychain (Sparkle account `anyfile`) and the `SPARKLE_PRIVATE_KEY` repository secret. Keep a backup: losing it means existing installs can't verify future updates.

To build a release locally without publishing: `Scripts/build-release.sh 1.1.0`. Output goes to `dist/`. The DMG background is drawn by `swift Scripts/make-dmg-background.swift`.

Builds are ad-hoc signed, not notarized, so the first install needs **System Settings → Privacy & Security → Open Anyway**. With an Apple Developer ID, sign and notarize in `build-release.sh`, then remove `disable-library-validation` from `AnyFile.entitlements`. The app is universal, but the bundled ffmpeg is Apple silicon only: on Intel Macs the ffmpeg formats need a Homebrew ffmpeg chosen in Settings.

## License note

The app bundles two separately licensed command-line tools, run as separate processes:

- **ffmpeg**: a static GPL build from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de) ([source](https://ffmpeg.org/download.html)).
- **mutool**: built from unmodified [MuPDF](https://mupdf.com) source, AGPL-3.0 ([source](https://mupdf.com/releases)).

It also includes SVGO's browser build (MIT, `AnyFile/Resources/svgo-LICENSE.txt`).

Distributing the DMG means passing those licenses on and pointing to the corresponding source, which these links do.
