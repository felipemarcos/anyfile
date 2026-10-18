import Foundation

enum FFmpegLocator {
    enum Source: Equatable { case custom(String), bundled, system(String) }

    static let systemPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]

    /// The user's custom ffmpeg when set, else the one bundled in the app, else a Homebrew/MacPorts install.
    /// An unusable custom path returns nil rather than silently using a different ffmpeg.
    static func find(customPath: String? = nil, bundle: Bundle = .main) -> URL? {
        if let customPath, !customPath.isEmpty {
            return FileManager.default.isExecutableFile(atPath: customPath) ? URL(fileURLWithPath: customPath) : nil
        }
        if let bundled = bundle.url(forResource: "ffmpeg", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in systemPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func source(of url: URL, customPath: String?, bundle: Bundle = .main) -> Source {
        if let customPath, !customPath.isEmpty, url.path == customPath { return .custom(url.path) }
        return url.path.hasPrefix(bundle.bundlePath) ? .bundled : .system(url.path)
    }

    /// Runs `-version` and returns the version string (e.g. "9.0.2"), or nil if it isn't a working ffmpeg.
    static func version(of url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-hide_banner", "-version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first,
              line.hasPrefix("ffmpeg version ") else { return nil }
        let version = line.dropFirst("ffmpeg version ".count).split(separator: " ").first ?? ""
        return String(version.split(separator: "-").first ?? version)
    }
}

/// Media conversion through an ffmpeg executable, for formats AVFoundation can't read or write.
struct FFmpegConverter: Converter {
    let executable: URL
    /// Encoders this ffmpeg build provides; targets whose encoder is missing are hidden.
    let encoders: Set<String>

    static let videoInputs: Set<FileFormat> = [.mp4, .mov, .m4v, .webm, .mkv, .avi, .gif]
    static let audioInputs: Set<FileFormat> = [.m4a, .wav, .aiff, .caf, .mp3, .flac, .ogg, .opus, .aac]
    static let imageInputs: Set<FileFormat> = [.png, .jpeg, .bmp, .tiff, .webp]

    init(executable: URL, encoders: Set<String>? = nil) {
        self.executable = executable
        self.encoders = encoders ?? Self.listEncoders(executable)
    }

    func targets(for input: FileFormat) -> [FileFormat] {
        let candidates: [FileFormat]
        if Self.videoInputs.contains(input) {
            candidates = [.mp4, .mov, .webm, .mkv, .avi, .gif, .webp, .mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus]
        } else if Self.audioInputs.contains(input) {
            candidates = [.mp3, .m4a, .aac, .wav, .aiff, .caf, .flac, .ogg, .opus]
        } else if Self.imageInputs.contains(input) {
            candidates = [.webp]
        } else {
            candidates = []
        }
        return candidates.filter { target in
            guard let args = Self.codecArguments(for: target, from: input) else { return false }
            return Self.requiredEncoders(in: args).isSubset(of: encoders)
        }
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard var codec = Self.codecArguments(for: target, from: source) else {
            throw ConversionError("ffmpeg can't convert \(source.displayName) to \(target.displayName).")
        }
        if target == .webp, Self.imageInputs.contains(source) {
            codec += ["-quality", String(Int(options.imageQuality * 100))]
        }
        let arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path] + codec
            + ["-progress", "pipe:1", "-nostats", output.path]
        try await run(arguments, progress: progress)
        progress(1)
        return output
    }

    // MARK: Arguments

    static func codecArguments(for target: FileFormat, from source: FileFormat) -> [String]? {
        let h264 = ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p"]
        let evenSize = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        let fromGIF = source == .gif
        switch target {
        case .mp4: return h264 + evenSize + (fromGIF ? ["-an"] : ["-c:a", "aac", "-b:a", "192k"]) + ["-movflags", "+faststart"]
        case .mov: return h264 + evenSize + (fromGIF ? ["-an"] : ["-c:a", "aac", "-b:a", "192k"])
        case .mkv: return h264 + evenSize + (fromGIF ? ["-an"] : ["-c:a", "aac", "-b:a", "192k"])
        case .webm: return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1"] + (fromGIF ? ["-an"] : ["-c:a", "libopus", "-b:a", "128k"])
        case .avi: return ["-c:v", "mpeg4", "-q:v", "3"] + (fromGIF ? ["-an"] : ["-c:a", "libmp3lame", "-q:a", "2"])
        case .gif:
            guard !fromGIF else { return nil }
            return ["-an", "-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse", "-loop", "0"]
        case .webp:
            if imageInputs.contains(source) { return ["-c:v", "libwebp", "-frames:v", "1"] }
            return ["-an", "-c:v", "libwebp", "-vf", "fps=12,scale='min(640,iw)':-2", "-loop", "0", "-quality", "75"]
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case .aac: return ["-vn", "-c:a", "aac", "-b:a", "256k", "-f", "adts"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        case .caf: return ["-vn", "-c:a", "pcm_s16le", "-f", "caf"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .ogg: return ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        default: return nil
        }
    }

    static func requiredEncoders(in arguments: [String]) -> Set<String> {
        var result = Set<String>()
        for (i, arg) in arguments.enumerated() where (arg == "-c:v" || arg == "-c:a") && i + 1 < arguments.count {
            result.insert(arguments[i + 1])
        }
        if arguments.contains(where: { $0.contains("paletteuse") }) { result.insert("gif") }
        return result
    }

    static func listEncoders(_ executable: URL) -> Set<String> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Lines look like " V....D libx264              libx264 H.264 ..."
        var names = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, parts[0] != "------" else { continue }
            names.insert(String(parts[1]))
        }
        return names
    }

    // MARK: Running

    private func run(_ arguments: [String], progress: @escaping ProgressHandler) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.appendStderr(handle.availableData)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if let fraction = state.appendStdout(handle.availableData) { progress(fraction) }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError("Couldn't start ffmpeg: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil

        try Task.checkCancellation()
        guard status == 0 else {
            throw ConversionError("ffmpeg failed: \(state.lastErrorLine ?? "exit code \(status)")")
        }
    }
}

/// Collects ffmpeg output from pipe callbacks and turns it into progress.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stderr = ""
    private var stdoutBuffer = ""
    private var duration: Double?

    func appendStderr(_ data: Data) {
        lock.withLock {
            stderr += String(decoding: data, as: UTF8.self)
            if stderr.count > 64_000 { stderr = String(stderr.suffix(32_000)) }
            if duration == nil, let match = stderr.firstMatch(of: /Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/) {
                let h = Double(match.1) ?? 0, m = Double(match.2) ?? 0, s = Double(match.3) ?? 0
                let total = h * 3600 + m * 60 + s
                if total > 0 { duration = total }
            }
        }
    }

    /// Returns the latest progress fraction, if this chunk carried one.
    func appendStdout(_ data: Data) -> Double? {
        lock.withLock {
            stdoutBuffer += String(decoding: data, as: UTF8.self)
            var fraction: Double?
            while let newline = stdoutBuffer.firstIndex(of: "\n") {
                let line = stdoutBuffer[..<newline]
                stdoutBuffer = String(stdoutBuffer[stdoutBuffer.index(after: newline)...])
                if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)),
                   let duration, duration > 0 {
                    fraction = min(micros / 1_000_000 / duration, 0.99)
                }
            }
            return fraction
        }
    }

    var lastErrorLine: String? {
        lock.withLock {
            stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty && !$0.hasPrefix("[out#") && !$0.hasPrefix("Conversion failed") }
        }
    }
}
