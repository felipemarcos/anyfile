import Foundation
import Observation

@MainActor
@Observable
final class ConversionJob: Identifiable {
    enum Status: Equatable {
        case pending
        case running(Double)
        case done(URL)
        case failed(String)
        case unsupported
    }

    let id = UUID()
    let input: URL
    let source: FileFormat?
    private(set) var availableTargets: [FileFormat]
    var target: FileFormat?
    var status: Status

    init(input: URL, registry: ConverterRegistry) {
        self.input = input
        let source = FileFormat.detect(input)
        self.source = source
        let targets = source.map(registry.targets(for:)) ?? []
        self.availableTargets = targets
        self.target = source.flatMap(Self.preferredTarget(for:)).flatMap { targets.contains($0) ? $0 : nil }
            ?? targets.first { $0.category == source?.category }
            ?? targets.first
        self.status = targets.isEmpty ? .unsupported : .pending
    }

    /// The most common conversion for each kind of file.
    private static func preferredTarget(for source: FileFormat) -> FileFormat? {
        switch source {
        case .heic, .webp, .tiff, .bmp, .gif: .jpeg
        case .jpeg: .png
        case .png: .jpeg
        case .mov, .m4v, .webm, .mkv, .avi: .mp4
        case .mp4: .mov
        case .wav, .aiff, .caf, .flac, .ogg, .opus, .aac: .mp3
        case .mp3: .m4a
        case .m4a: .mp3
        case .docx, .odt, .rtf, .html, .markdown: .pdf
        case .txt: .pdf
        case .pdf, .ai: .svg
        case .svg: .png
        case .csv, .xlsx, .plist: .json
        case .json: .csv
        }
    }

    /// Recomputes targets after the set of converters changed (e.g. a different ffmpeg).
    func refresh(registry: ConverterRegistry) {
        guard !isRunning, let source else { return }
        availableTargets = registry.targets(for: source)
        if let target, availableTargets.contains(target) { return }
        target = Self.preferredTarget(for: source).flatMap { availableTargets.contains($0) ? $0 : nil }
            ?? availableTargets.first { $0.category == source.category }
            ?? availableTargets.first
        if availableTargets.isEmpty { status = .unsupported } else if status == .unsupported { status = .pending }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    var canConvert: Bool {
        guard target != nil else { return false }
        switch status {
        case .pending, .failed, .done: return true
        case .running, .unsupported: return false
        }
    }
}
