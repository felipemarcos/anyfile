import Foundation
import Observation

@MainActor
@Observable
final class ConversionQueue {
    private(set) var jobs: [ConversionJob] = []
    private(set) var registry: ConverterRegistry
    private(set) var ffmpegURL: URL?
    private(set) var ffmpegVersion: String?
    private var task: Task<Void, Never>?

    /// Conversions that run at the same time.
    let maxConcurrent = 3

    init(ffmpegPath: String? = nil) {
        registry = .standard(ffmpeg: nil)
        configureFFmpeg(customPath: ffmpegPath)
    }

    /// Picks the ffmpeg to use (custom path, else bundled, else system) and rebuilds the converters.
    func configureFFmpeg(customPath: String?) {
        var url = FFmpegLocator.find(customPath: customPath)
        let version = url.flatMap(FFmpegLocator.version(of:))
        if version == nil { url = nil }
        ffmpegURL = url
        ffmpegVersion = version
        registry = .standard(ffmpeg: url)
        for job in jobs { job.refresh(registry: registry) }
    }

    var isConverting: Bool { task != nil }

    var hasConvertibleJobs: Bool { jobs.contains { $0.canConvert } }

    /// Targets every convertible job shares, for the "Convert all to" menu.
    var commonTargets: [FileFormat] {
        let sets = jobs.filter { !$0.availableTargets.isEmpty }.map { Set($0.availableTargets) }
        guard let first = sets.first else { return [] }
        let common = sets.dropFirst().reduce(first) { $0.intersection($1) }
        return FileFormat.allCases.filter(common.contains)
    }

    func add(_ urls: [URL]) {
        let existing = Set(jobs.map(\.input))
        for url in urls where !existing.contains(url) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            jobs.append(ConversionJob(input: url, registry: registry))
        }
    }

    func remove(_ job: ConversionJob) {
        guard !job.isRunning else { return }
        jobs.removeAll { $0.id == job.id }
    }

    /// Removes these jobs, skipping any that are converting.
    func remove(ids: Set<ConversionJob.ID>) {
        jobs.removeAll { ids.contains($0.id) && !$0.isRunning }
    }

    func clear() {
        jobs.removeAll { !$0.isRunning }
    }

    func setTargetForAll(_ format: FileFormat) {
        for job in jobs where job.availableTargets.contains(format) && !job.isRunning {
            job.target = format
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// Converts every pending job (or only `only`, when given).
    func start(only: [ConversionJob]? = nil, settings: AppSettings) {
        guard task == nil else { return }
        let selected = (only ?? jobs).filter { job in
            guard job.canConvert else { return false }
            if only == nil, case .done = job.status { return false }
            return true
        }
        guard !selected.isEmpty else { return }

        let registry = registry
        let options = settings.options
        let outputFolder = settings.outputFolder

        let limit = maxConcurrent
        task = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = selected.makeIterator()
                func addNext() -> Bool {
                    guard let job = iterator.next() else { return false }
                    group.addTask {
                        await Self.run(job, registry: registry, options: options, outputFolder: outputFolder)
                    }
                    return true
                }
                for _ in 0..<limit {
                    if !addNext() { break }
                }
                for await _ in group {
                    if Task.isCancelled { group.cancelAll(); continue }
                    _ = addNext()
                }
            }
            for job in selected where job.isRunning {
                job.status = .failed("Cancelled")
            }
            self?.task = nil
        }
    }

    private static func run(_ job: ConversionJob, registry: ConverterRegistry, options: ConversionOptions, outputFolder: URL?) async {
        guard let source = job.source, let target = job.target,
              let converter = registry.converter(from: source, to: target) else {
            job.status = .failed("No converter for this format pair")
            return
        }
        job.status = .running(0)
        let input = job.input
        let directory = outputFolder ?? input.deletingLastPathComponent()
        let output = OutputNamer.uniqueURL(for: input, ext: target.fileExtension, in: directory)

        let progress: ProgressHandler = { value in
            Task { @MainActor in
                if case .running = job.status { job.status = .running(min(max(value, 0), 1)) }
            }
        }

        let accessing = input.startAccessingSecurityScopedResource()
        defer { if accessing { input.stopAccessingSecurityScopedResource() } }

        do {
            let written = try await converter.convert(input, from: source, to: target, output: output, options: options, progress: progress)
            job.status = .done(written)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: output)
            job.status = .failed("Cancelled")
        } catch {
            try? FileManager.default.removeItem(at: output)
            job.status = .failed(error.localizedDescription)
        }
    }
}
