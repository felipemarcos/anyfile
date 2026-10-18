import AVFoundation
import Foundation
import Testing
@testable import AnyFile

/// Uses ffmpeg to generate fixtures, so the suite is skipped when none is installed.
@Suite(.enabled(if: FFmpegLocator.find() != nil, "needs ffmpeg"))
struct MediaTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")
    let ffmpeg = FFmpegConverter(executable: FFmpegLocator.find()!)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func fixture(_ name: String, _ args: [String]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let process = Process()
        process.executableURL = ffmpeg.executable
        process.arguments = ["-loglevel", "error", "-y"] + args + [url.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return url
    }

    private func clip() throws -> URL {
        try fixture("clip.mov", ["-f", "lavfi", "-i", "testsrc=size=160x120:rate=25", "-f", "lavfi", "-i", "sine=frequency=440",
                                 "-t", "2", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"])
    }

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    @Test func avFoundationVideoAndAudio() async throws {
        let mov = try clip()
        let mp4 = dir.appendingPathComponent("clip.mp4")
        let m4a = dir.appendingPathComponent("clip.m4a")
        _ = try await AVConverter().convert(mov, from: .mov, to: .mp4, output: mp4, options: .init(), progress: { _ in })
        _ = try await AVConverter().convert(mov, from: .mov, to: .m4a, output: m4a, options: .init(), progress: { _ in })
        #expect(abs(try await duration(mp4) - 2) < 0.2)
        #expect(abs(try await duration(m4a) - 2) < 0.2)

        let aiff = dir.appendingPathComponent("tone.aiff")
        _ = try await AVConverter().convert(m4a, from: .m4a, to: .aiff, output: aiff, options: .init(), progress: { _ in })
        let file = try AVAudioFile(forReading: aiff)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 2) < 0.2)
    }

    @Test func ffmpegConversionsReportProgress() async throws {
        let mov = try clip()
        let progress = ProgressLog()
        for target in [FileFormat.webm, .mkv, .gif, .mp3, .flac, .opus] where ffmpeg.targets(for: .mov).contains(target) {
            let out = dir.appendingPathComponent("clip").appendingPathExtension(target.fileExtension)
            _ = try await ffmpeg.convert(mov, from: .mov, to: target, output: out, options: .init(), progress: progress.record)
            let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
            #expect(size > 0, "\(target) is empty")
        }
        #expect(progress.values.contains(1))
    }

    @Test func ffmpegErrorsAreReadable() async throws {
        let bogus = dir.appendingPathComponent("bogus.mp4")
        try Data("not a video".utf8).write(to: bogus)
        let out = dir.appendingPathComponent("bogus.webm")
        await #expect(throws: ConversionError.self) {
            _ = try await ffmpeg.convert(bogus, from: .mp4, to: .webm, output: out, options: .init(), progress: { _ in })
        }
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    var values: [Double] { lock.withLock { stored } }
    var record: ProgressHandler { { value in self.lock.withLock { self.stored.append(value) } } }
}
