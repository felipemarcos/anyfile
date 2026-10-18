# AnyFile

A SwiftUI macOS app that converts files locally. Nothing is uploaded.

Drop files on the window (or the Dock icon, or use **Open With → AnyFile**), pick a target format per file or with **Set All To**, and press **Convert** (⌘↩). Output goes next to the original, or to a folder chosen in Settings. Existing files are never overwritten.

| Input | Output | Engine |
|---|---|---|
| PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP | PNG, JPEG, HEIC, TIFF, GIF, BMP, PDF (+ WebP via ffmpeg) | ImageIO |
| MOV, MP4, M4V | MP4, MOV, M4V, M4A | AVFoundation |
| M4A, WAV, AIFF, CAF, MP3, AAC | M4A, WAV, AIFF, CAF | AVFoundation |
| Video incl. WebM, MKV, AVI, GIF | MP4, MOV, WebM, MKV, AVI, GIF, WebP, MP3, M4A, AAC, WAV, AIFF, FLAC, OGG, Opus | ffmpeg |
| Audio incl. FLAC, OGG, Opus | MP3, M4A, AAC, WAV, AIFF, CAF, FLAC, OGG, Opus | ffmpeg |
| TXT, RTF, DOCX, HTML, ODT, Markdown | TXT, RTF, DOCX, HTML, ODT, PDF | NSAttributedString |
| PDF | PNG, JPEG, TIFF (one file per page), TXT | PDFKit |
| CSV ↔ JSON ↔ Excel (XLSX), JSON ↔ plist | | built in (+ ZIPFoundation) |

Data notes: JSON key order becomes column order; CSV columns are typed only when every value converts losslessly (so `01234` stays a string); Excel dates become ISO 8601 strings; legacy `.xls` isn't supported.

## Build

Requires Xcode 27 and macOS 14+.

```sh
Scripts/fetch-ffmpeg.sh   # optional: bundle a static ffmpeg (~28 MB download)
xcodebuild -project AnyFile.xcodeproj -scheme AnyFile -destination 'platform=macOS' build test
```

`Scripts/fetch-ffmpeg.sh` puts a static ffmpeg in `Vendor/ffmpeg` (gitignored), and the build copies and signs it into the app. In **Settings → ffmpeg** you can stay on **Automatic** (bundled, then Homebrew/MacPorts) or choose a custom ffmpeg executable; Settings shows the version in use. With no working ffmpeg, the ffmpeg-only formats are hidden.

The app icon is drawn by `swift Scripts/make-icon.swift`, which regenerates `AnyFile/Assets.xcassets/AppIcon.appiconset`.

The project uses Xcode's classic `project.pbxproj` file; once on Xcode 27.2+, switch to the JSON `project.xcproj` format with:

```sh
xcodebuild -project AnyFile.xcodeproj -convert-project "Xcode Project"
```

## License note

The fetched ffmpeg is a static GPL build from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de). That's fine for personal use; distributing the app with it bundled brings GPL obligations.
