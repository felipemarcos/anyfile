import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(ConversionQueue.self) private var queue
    @Environment(AppSettings.self) private var settings

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
                Text("MuPDF converts PDF and Illustrator files to SVG and HTML, and SVG to PNG or PDF.")
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
