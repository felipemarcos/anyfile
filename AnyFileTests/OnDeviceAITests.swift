import AppKit
import Foundation
import ImageIO
import Speech
import Testing
@testable import AnyFile

struct SubtitlesTests {
    typealias Word = Subtitles.Word

    private func words(_ text: String, start: Double = 0, perWord: Double = 0.4) -> [Word] {
        text.split(separator: " ").enumerated().map { i, w in
            Word(text: " " + w, start: start + Double(i) * perWord, end: start + Double(i) * perWord + perWord * 0.9)
        }
    }

    @Test func breaksAtSentencesPausesAndLimits() {
        let speech = words("Welcome to the app. This sentence is long enough to need a second line on screen.")
            + words("After a pause.", start: 30)
        let cues = Subtitles.cues(from: speech)
        #expect(cues.first?.lines == ["Welcome to the app."])
        #expect(cues.allSatisfy { $0.lines.count <= 2 && $0.lines.allSatisfy { $0.count <= Subtitles.maxLineLength } })
        #expect(cues.allSatisfy { $0.end - $0.start <= Subtitles.maxDuration + 0.5 })
        #expect(cues.last?.lines == ["After a pause."])
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    @Test func formatsSRTAndVTT() {
        let cues = [Subtitles.Cue(start: 0, end: 1.5, lines: ["Hello"]), Subtitles.Cue(start: 3661.25, end: 3662, lines: ["Two", "lines"])]
        #expect(Subtitles.srt(cues) == "1\n00:00:00,000 --> 00:00:01,500\nHello\n\n2\n01:01:01,250 --> 01:01:02,000\nTwo\nlines\n")
        #expect(Subtitles.vtt(cues) == "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello\n\n01:01:01.250 --> 01:01:02.000\nTwo\nlines\n")
    }

    @Test func plainTextStartsParagraphsAfterLongPauses() {
        let text = Subtitles.plainText(words("First part here.") + words("Second part.", start: 10))
        #expect(text == "First part here.\n\nSecond part.\n")
    }

    @Test func splitsLongLinesNearTheMiddle() {
        let lines = Subtitles.split("This app converts files on your Mac without uploading anything.")
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= Subtitles.maxLineLength })
    }
}

struct VectorizerTests {
    /// A flat three-color logo: white background, navy circle, orange square.
    private func logo(width: Int = 400, height: Int = 300, transparent: Bool = false) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.15, blue: 0.45, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 40, y: 40, width: 200, height: 200))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.55, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 260, y: 80, width: 100, height: 100))
        return ctx.makeImage()!
    }

    private func render(_ svg: String, width: Int, height: Int) throws -> CGImage {
        let image = try #require(NSImage(data: Data(svg.utf8)))
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// Share of pixels whose color differs by more than 32 on any channel.
    private func mismatch(_ a: CGImage, _ b: CGImage) throws -> Double {
        let pa = try Vectorizer.rgba(a, width: a.width, height: a.height), pb = try Vectorizer.rgba(b, width: a.width, height: a.height)
        var bad = 0
        for i in stride(from: 0, to: pa.count, by: 4) where (0..<4).contains(where: { abs(Int(pa[i + $0]) - Int(pb[i + $0])) > 32 }) {
            bad += 1
        }
        return Double(bad) / Double(pa.count / 4)
    }

    @Test func flatLogoKeepsItsPaletteAndShapes() throws {
        let image = logo()
        let svg = try Vectorizer(settings: .init()).svg(for: image)
        let fills = Set(svg.matches(of: /fill="(#[0-9a-f]{6})"/).map { String($0.1) })
        #expect(fills.count == 3, "fills: \(fills)")
        #expect(fills.contains("#ffffff"))
        #expect(svg.contains(#"viewBox="0 0 400 300""#))
        #expect(try mismatch(image, render(svg, width: 400, height: 300)) < 0.01)
    }

    @Test func fixedColorCountAndTransparency() throws {
        let svg = try Vectorizer(settings: .init(colors: 2)).svg(for: logo(transparent: true))
        #expect(Set(svg.matches(of: /fill="(#[0-9a-f]{6})"/).map { String($0.1) }).count == 2)
        #expect(!svg.contains("H400V300H0Z")) // no full-canvas background when the image is transparent
    }

    @Test func sameImageSameSVG() throws {
        let image = logo()
        #expect(try Vectorizer(settings: .init()).svg(for: image) == Vectorizer(settings: .init()).svg(for: image))
    }

    @Test func transparentImageIsRejected() throws {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        #expect(throws: ConversionError.self) { try Vectorizer(settings: .init()).svg(for: ctx.makeImage()!) }
    }

    @Test func converterWritesOptimizedSVG() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("logo.png")
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, logo(), nil)
        #expect(CGImageDestinationFinalize(dest))
        let svg = dir.appendingPathComponent("logo.svg")
        let converter = try #require(ConverterRegistry.standard(ffmpeg: nil).converter(from: .png, to: .svg))
        _ = try await converter.convert(png, from: .png, to: .svg, output: svg, options: .init(), progress: { _ in })
        let text = try String(contentsOf: svg, encoding: .utf8)
        #expect(text.hasPrefix("<svg"))
        #expect(text.count < 4000)
    }
}

struct BackgroundRemovalTests {
    static let sample = URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sample.path), "needs macOS's sample user pictures"))
    func removesTheBackgroundAroundTheSubject() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("parrot.png")
        _ = try await BackgroundRemover().convert(Self.sample, from: .heic, to: .cutoutPNG, output: out, options: .init(), progress: { _ in })
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try Vectorizer.rgba(image, width: image.width, height: image.height)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * image.width + x) * 4 + 3] }
        // The parrot fills the centre; the top-left corner is background.
        #expect(alpha(image.width / 2, image.height / 2) == 255)
        #expect(alpha(4, 4) == 0)

        let cropped = dir.appendingPathComponent("cropped.png")
        _ = try await BackgroundRemover().convert(Self.sample, from: .heic, to: .cutoutPNG, output: cropped,
                                                  options: .init(cropCutoutToSubject: true), progress: { _ in })
        let croppedSource = try #require(CGImageSourceCreateWithURL(cropped as CFURL, nil))
        let croppedImage = try #require(CGImageSourceCreateImageAtIndex(croppedSource, 0, nil))
        #expect(croppedImage.width <= image.width && croppedImage.height <= image.height)
    }

    @Test func formatsAndNaming() {
        #expect(FileFormat.cutoutPNG.fileExtension == "png")
        #expect(FileFormat.cutoutPNG.outputNameSuffix == " (no background)")
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.png")) == .png)
        let registry = ConverterRegistry.standard(ffmpeg: nil)
        #expect(registry.targets(for: .jpeg).contains(.cutoutPNG))
        #expect(registry.targets(for: .jpeg).contains(.svg))
        #expect(registry.targets(for: .mp3).contains(.srt))
        #expect(registry.targets(for: .mov).contains(.vtt))
        #expect(!registry.targets(for: .webm).contains(.srt)) // needs ffmpeg to read
    }
}

/// Speaks a sentence with the system voice and transcribes it. Skipped where the
/// English speech model isn't installed (e.g. CI), since that needs a download.
struct TranscriptionTests {
    @Test func transcribesSpeechToSubtitles() async throws {
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              await SpeechTranscriber.installedLocales.contains(where: { $0.identifier(.bcp47).hasPrefix("en") }) else {
            print("Skipping: no installed English speech model")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, "The quick brown fox jumps over the lazy dog. Converting files is easy."]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { print("Skipping: no Samantha voice"); return }

        let srt = dir.appendingPathComponent("speech.srt")
        _ = try await TranscriptConverter(ffmpeg: nil).convert(audio, from: .aiff, to: .srt, output: srt,
                                                                 options: .init(transcriptionLocale: "en-US"), progress: { _ in })
        let text = try String(contentsOf: srt, encoding: .utf8)
        #expect(text.hasPrefix("1\n00:00:00"))
        #expect(text.lowercased().contains("quick brown fox"))
        #expect(text.lowercased().contains("converting files"))
    }
}
