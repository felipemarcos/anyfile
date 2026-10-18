import Foundation
import Testing
@testable import AnyFile

struct FFmpegLocatorTests {
    @Test func customPathWinsWhenExecutable() throws {
        let fake = FileManager.default.temporaryDirectory.appendingPathComponent("fake-ffmpeg-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho 'ffmpeg version 7.1-custom Copyright'\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        #expect(FFmpegLocator.find(customPath: fake.path) == fake)
        #expect(FFmpegLocator.source(of: fake, customPath: fake.path) == .custom(fake.path))
        #expect(FFmpegLocator.version(of: fake) == "7.1")
    }

    @Test func invalidCustomPathDoesNotFallBack() {
        #expect(FFmpegLocator.find(customPath: "/nonexistent/ffmpeg") == nil)
        #expect(FFmpegLocator.version(of: URL(fileURLWithPath: "/bin/echo")) == nil)
    }

    @Test func bundledFFmpegIsFoundAndWorks() throws {
        // The test host is AnyFile.app, so Bundle.main is the app bundle.
        guard let url = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) else {
            withKnownIssue("Vendor/ffmpeg not fetched; nothing bundled") { Issue.record("no bundled ffmpeg") }
            return
        }
        #expect(FFmpegLocator.find() == url)
        #expect(FFmpegLocator.source(of: url, customPath: nil) == .bundled)
        #expect(FFmpegLocator.version(of: url) != nil)
    }

    @Test @MainActor func switchingFFmpegRefreshesJobs() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mkv")
        try Data().write(to: file)
        let queue = ConversionQueue(ffmpegPath: "/nonexistent/ffmpeg")
        queue.add([file])
        let job = try #require(queue.jobs.first)
        #expect(job.status == .unsupported)

        queue.configureFFmpeg(customPath: nil)
        guard queue.ffmpegURL != nil else { return } // no ffmpeg on this machine
        #expect(job.status == .pending)
        #expect(job.target == .mp4)
    }
}
