import AppKit
import Speech
import SwiftUI

struct SettingsView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(AppSettings.self) private var settings
    @State private var transcriptionLocales: [String] = []

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Output") {
                Picker("Save converted files", selection: Binding(
                    get: { settings.outputFolder == nil ? 0 : 1 },
                    set: { choice in
                        if choice == 0 { settings.outputFolder = nil } else { chooseFolder() }
                    }
                )) {
                    Text("Next to the original").tag(0)
                    Text(settings.outputFolder.map { "In \($0.lastPathComponent)" } ?? "In a folder…").tag(1)
                }
                if let folder = settings.outputFolder {
                    LabeledContent("Folder") {
                        HStack {
                            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Change…", action: chooseFolder)
                        }
                    }
                }
                Text("Existing files are never overwritten. A number is added to the name instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Images") {
                LabeledContent("JPEG, HEIC and WebP quality") {
                    HStack {
                        Slider(value: $settings.imageQuality, in: 0.3...1, step: 0.05)
                            .frame(width: 180)
                        Text("\(Int(settings.imageQuality * 100))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Render resolution", selection: $settings.renderDPI) {
                    ForEach(AppSettings.renderDPIPresets, id: \.0) { dpi, label in
                        Text(label).tag(dpi)
                    }
                }
                Text("Pixel size when PDF pages, Illustrator files and SVGs become PNG, JPEG or other images. A US Letter page at 2× is 1224 × 1584 px; at 600 dpi it's 5100 × 6600 px.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Text recognition (OCR)") {
                Picker("Language", selection: $settings.ocrLanguage) {
                    Text("Automatic").tag(String?.none)
                    Divider()
                    ForEach(ocrLanguages, id: \.code) { language in
                        Text(language.name).tag(Optional(language.code))
                    }
                }
                Toggle("Recognize scanned pages when extracting text from PDFs", isOn: $settings.ocrScannedPages)
                Text("Convert a PDF or image to \u{201C}Searchable PDF (OCR)\u{201D} to make its text selectable and searchable. Recognition runs on this Mac with Apple\u{2019}s Vision framework.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vectorize (image → SVG)") {
                Picker("Colors", selection: $settings.vectorizeColors) {
                    Text("Automatic").tag(0)
                    ForEach([2, 4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Outlines", selection: $settings.vectorizeTolerance) {
                    Text("Precise").tag(0.5)
                    Text("Balanced").tag(1.0)
                    Text("Smooth").tag(2.0)
                }
                Text("Best for logos, icons and flat artwork. Automatic finds the image\u{2019}s own palette; gradients come out as bands, so try 32 colors for them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background removal") {
                Toggle("Crop to the subject", isOn: $settings.cropCutoutToSubject)
                Text("\u{201C}PNG (background removed)\u{201D} keeps the subject on a transparent background, using the same on-device model as Photos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Language", selection: $settings.transcriptionLocale) {
                    Text("System (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))").tag(String?.none)
                    Divider()
                    ForEach(transcriptionLocales, id: \.self) { code in
                        Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(Optional(code))
                    }
                }
                .task { await loadTranscriptionLocales() }
                Text("Audio and video become text or subtitles (SRT, WebVTT) on this Mac. The first time you use a language, macOS downloads its speech model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Excel") {
                Toggle("Export every sheet when converting to JSON", isOn: $settings.allSheets)
                Text("When on, the JSON is an object keyed by sheet name. CSV always uses the first sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ffmpeg") {
                Picker("Use", selection: Binding(
                    get: { settings.ffmpegPath == nil ? 0 : 1 },
                    set: { choice in
                        if choice == 0 { setFFmpegPath(nil) } else { chooseFFmpeg() }
                    }
                )) {
                    Text("Automatic").tag(0)
                    Text("Custom…").tag(1)
                }
                if let path = settings.ffmpegPath {
                    LabeledContent("Path") {
                        HStack {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("Change…", action: chooseFFmpeg)
                        }
                    }
                }
                LabeledContent("Status") {
                    Text(ffmpegStatus)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(queue.ffmpegURL == nil ? .orange : .secondary)
                }
                Text("Automatic uses the ffmpeg bundled with AnyFile, falling back to Homebrew or MacPorts. ffmpeg adds WebM, MKV, AVI, MP3, FLAC, OGG, Opus, WebP and GIF-from-video conversions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("MuPDF") {
                LabeledContent("Status") {
                    Text(mupdfStatus)
                        .foregroundStyle(MuPDFLocator.find() == nil ? .orange : .secondary)
                }
                Toggle("Optimize SVG output with SVGO", isOn: $settings.optimizeSVG)
                Text("MuPDF converts PDF and Illustrator files to SVG and HTML. SVGO, the engine behind SVGOMG, then shrinks each SVG on this Mac with SVGOMG's default settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ffmpegStatus: String {
        guard let url = queue.ffmpegURL else {
            return settings.ffmpegPath == nil
                ? "Not found. Media conversions are limited to Apple formats."
                : "That file isn't a working ffmpeg. Media conversions are limited to Apple formats."
        }
        let version = queue.ffmpegVersion.map { "ffmpeg \($0)" } ?? "ffmpeg"
        switch FFmpegLocator.source(of: url, customPath: settings.ffmpegPath) {
        case .custom: return "Using \(version)"
        case .bundled: return "Using bundled \(version)"
        case .system(let path): return "Using \(version) at \((path as NSString).abbreviatingWithTildeInPath)"
        }
    }

    /// Vision's languages with readable names, sorted by name.
    private var ocrLanguages: [(code: String, name: String)] {
        TextRecognizer.supportedLanguages
            .map { (code: $0, name: Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func loadTranscriptionLocales() async {
        guard transcriptionLocales.isEmpty else { return }
        var codes: [String]
        if #available(macOS 26, *) {
            codes = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        } else {
            codes = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        }
        codes = Array(Set(codes))
        transcriptionLocales = codes.sorted {
            (Locale.current.localizedString(forIdentifier: $0) ?? $0)
                .localizedCaseInsensitiveCompare(Locale.current.localizedString(forIdentifier: $1) ?? $1) == .orderedAscending
        }
    }

    private var mupdfStatus: String {
        guard let url = MuPDFLocator.find() else { return "Not found. SVG conversions are unavailable." }
        return url.path.hasPrefix(Bundle.main.bundlePath)
            ? "Bundled with AnyFile"
            : "Using \((url.path as NSString).abbreviatingWithTildeInPath)"
    }

    private func setFFmpegPath(_ path: String?) {
        settings.ffmpegPath = path
        queue.configureFFmpeg(customPath: path)
    }

    private func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose an ffmpeg executable"
        panel.prompt = "Use"
        let current = settings.ffmpegPath ?? FFmpegLocator.systemPaths.first { FileManager.default.fileExists(atPath: $0) }
        panel.directoryURL = current.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url {
            setFFmpegPath(url.path)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.outputFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }
}
