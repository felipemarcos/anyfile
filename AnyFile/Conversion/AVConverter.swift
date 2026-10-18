@preconcurrency import AVFoundation
import Foundation

/// Audio and video conversion with AVFoundation.
struct AVConverter: Converter {
    static let videoInputs: Set<FileFormat> = [.mp4, .mov, .m4v]
    static let audioInputs: Set<FileFormat> = [.m4a, .wav, .aiff, .caf, .mp3, .aac]

    func targets(for input: FileFormat) -> [FileFormat] {
        if Self.videoInputs.contains(input) { return [.mp4, .mov, .m4v, .m4a] }
        if Self.audioInputs.contains(input) { return [.m4a, .wav, .aiff, .caf] }
        return []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        switch target {
        case .wav, .aiff, .caf:
            try await Self.writePCM(from: input, to: target, output: output, progress: progress)
        case .m4a:
            try await Self.export(input, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, output: output, progress: progress)
        case .mp4:
            try await Self.export(input, preset: AVAssetExportPresetHighestQuality, fileType: .mp4, output: output, progress: progress)
        case .mov:
            try await Self.export(input, preset: AVAssetExportPresetHighestQuality, fileType: .mov, output: output, progress: progress)
        case .m4v:
            try await Self.export(input, preset: AVAssetExportPresetHighestQuality, fileType: .m4v, output: output, progress: progress)
        default:
            throw ConversionError("Unsupported target \(target.displayName).")
        }
        return output
    }

    private static func export(_ input: URL, preset: String, fileType: AVFileType, output: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: input)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError("This file can't be exported with AVFoundation.")
        }
        let session = SendableBox(exportSession).value
        guard session.supportedFileTypes.contains(fileType) else {
            throw ConversionError("This file can't be exported to .\(output.pathExtension).")
        }
        if #available(macOS 15, *) {
            let box = SendableBox(session)
            let monitor = Task {
                let session = box.value
                for await state in session.states(updateInterval: 0.2) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            defer { monitor.cancel() }
            try await session.export(to: output, as: fileType)
        } else {
            session.outputURL = output
            session.outputFileType = fileType
            let box = SendableBox(session)
            let monitor = Task {
                let session = box.value
                while !Task.isCancelled {
                    progress(Double(session.progress))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { monitor.cancel() }
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                box.value.cancelExport()
            }
            try Task.checkCancellation()
            if let error = session.error { throw error }
            guard session.status == .completed else { throw ConversionError("Export didn't finish.") }
        }
        progress(1)
    }

    /// Decodes any AVAudioFile-readable audio and re-encodes it as 16-bit PCM.
    private static func writePCM(from input: URL, to target: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws {
        let inFile = try AVAudioFile(forReading: input)
        let format = inFile.processingFormat
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: target == .aiff,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if target == .caf { settings[AVLinearPCMIsBigEndianKey] = false }

        let outFile = try AVAudioFile(forWriting: output, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let total = max(inFile.length, 1)
        let capacity: AVAudioFrameCount = 1 << 15
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError("Couldn't allocate an audio buffer.")
        }
        while inFile.framePosition < inFile.length {
            try Task.checkCancellation()
            try inFile.read(into: buffer, frameCount: capacity)
            if buffer.frameLength == 0 { break }
            try outFile.write(from: buffer)
            progress(Double(inFile.framePosition) / Double(total))
        }
    }
}

/// Lets a non-Sendable AVFoundation object be read from a progress-monitoring task.
private struct SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
