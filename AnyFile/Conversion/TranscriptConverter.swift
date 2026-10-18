@preconcurrency import AVFoundation
import Foundation
import Speech

/// Audio and video → transcript (TXT) or subtitles (SRT, WebVTT), recognized on-device.
/// macOS 26+ uses SpeechAnalyzer/SpeechTranscriber; earlier versions use SFSpeechRecognizer
/// with on-device recognition required. Audio never leaves the Mac; the first use of a
/// language may download Apple's speech model for it.
struct TranscriptConverter: Converter {
    /// Used to extract audio from containers AVFoundation can't read (WebM, MKV, OGG…).
    let ffmpeg: URL?

    static let audioInputs: Set<FileFormat> = [.m4a, .wav, .aiff, .caf, .mp3, .aac, .flac, .ogg, .opus]
    static let videoInputs: Set<FileFormat> = [.mp4, .mov, .m4v, .webm, .mkv, .avi]

    func targets(for input: FileFormat) -> [FileFormat] {
        let readable = Self.audioInputs.contains(input) || Self.videoInputs.contains(input)
        guard readable else { return [] }
        // Containers only ffmpeg can open need ffmpeg to pull the audio out.
        if [.webm, .mkv, .avi, .ogg, .opus].contains(input), ffmpeg == nil { return [] }
        return [.txt, .srt, .vtt]
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let audio = try await audioFile(for: input, in: work)
        progress(0.1)
        let locale = options.transcriptionLocale.map(Locale.init(identifier:)) ?? Locale.current
        let words: [Subtitles.Word]
        if #available(macOS 26, *) {
            words = try await Self.transcribeWithSpeechAnalyzer(audio, locale: locale, progress: progress)
        } else {
            words = try await Self.transcribeWithSFSpeech(audio, locale: locale)
        }
        guard !words.isEmpty else { throw ConversionError("No speech was recognized.") }

        let text: String
        switch target {
        case .srt: text = Subtitles.srt(Subtitles.cues(from: words))
        case .vtt: text = Subtitles.vtt(Subtitles.cues(from: words))
        default: text = Subtitles.plainText(words)
        }
        try Data(text.utf8).write(to: output, options: .atomic)
        progress(1)
        return output
    }

    /// An audio file AVAudioFile can read: the input itself, or its audio track extracted.
    private func audioFile(for input: URL, in work: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: input)) != nil { return input }
        let wav = work.appendingPathComponent("audio.wav")
        if let ffmpeg {
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return wav }
        }
        // AVFoundation can still pull the audio out of MP4/MOV.
        let m4a = work.appendingPathComponent("audio.m4a")
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A) else {
            throw ConversionError("Couldn't read the audio in this file.")
        }
        session.outputURL = m4a
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed else {
            throw ConversionError("Couldn't read the audio in this file\(session.error.map { ": \($0.localizedDescription)" } ?? ".")")
        }
        return m4a
    }

    // MARK: macOS 26+

    @available(macOS 26, *)
    static func transcribeWithSpeechAnalyzer(_ audio: URL, locale: Locale, progress: @escaping ProgressHandler) async throws -> [Subtitles.Word] {
        guard SpeechTranscriber.isAvailable else { throw ConversionError("Speech recognition isn't available on this Mac.") }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ConversionError("Transcription doesn't support \(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier). Pick another language in Settings.")
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall() // one-time model download for this language
        }

        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Subtitles.Word] in
            var words: [Subtitles.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    words.append(Subtitles.Word(text: text, start: range.start.seconds, end: range.end.seconds))
                    if duration > 0 { progress(0.1 + 0.85 * min(range.end.seconds / duration, 1)) }
                }
            }
            return words
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        return try await collector.value
    }

    // MARK: Before macOS 26

    static func transcribeWithSFSpeech(_ audio: URL, locale: Locale) async throws -> [Subtitles.Word] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw ConversionError("Allow AnyFile to use Speech Recognition in System Settings → Privacy & Security.")
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw ConversionError("On-device transcription isn't available for this language.")
        }
        let request = SFSpeechURLRecognitionRequest(url: audio)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription.segments.map {
                        Subtitles.Word(text: $0.substring, start: $0.timestamp, end: $0.timestamp + $0.duration)
                    })
                }
            }
        }
    }
}
