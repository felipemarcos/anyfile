import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import AnyFile

struct ConverterTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func makePNG(width: Int = 40, height: Int = 30) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = dir.appendingPathComponent("image.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func size(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    @Test func imageConversionsKeepDimensions() async throws {
        let png = try makePNG()
        for target in [FileFormat.jpeg, .heic, .tiff, .bmp, .gif] {
            let out = dir.appendingPathComponent("out").appendingPathExtension(target.fileExtension)
            _ = try await ImageConverter().convert(png, from: .png, to: target, output: out, options: .init(), progress: { _ in })
            let dims = try #require(size(of: out), "\(target) unreadable")
            #expect(dims == (40, 30), "\(target)")
        }
    }

    @Test func imageToPDFAndBack() async throws {
        let png = try makePNG()
        let pdf = dir.appendingPathComponent("image.pdf")
        _ = try await ImageConverter().convert(png, from: .png, to: .pdf, output: pdf, options: .init(), progress: { _ in })
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.pageCount == 1)

        let back = dir.appendingPathComponent("page.png")
        let written = try await PDFConverter().convert(pdf, from: .pdf, to: .png, output: back, options: .init(), progress: { _ in })
        #expect(written == back)
        #expect(size(of: back).map { $0 == (80, 60) } == true) // rendered at 144 dpi
    }

    @Test @MainActor func documentRoundTripKeepsText() async throws {
        let rtf = dir.appendingPathComponent("doc.rtf")
        let text = NSAttributedString(string: "Hello, wörld!\nSecond line.", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        try DocumentConverter.write(text, as: .rtf).write(to: rtf)

        let converter = DocumentConverter()
        let docx = dir.appendingPathComponent("doc.docx")
        let txt = dir.appendingPathComponent("doc.txt")
        let pdf = dir.appendingPathComponent("doc.pdf")
        _ = try await converter.convert(rtf, from: .rtf, to: .docx, output: docx, options: .init(), progress: { _ in })
        _ = try await converter.convert(docx, from: .docx, to: .txt, output: txt, options: .init(), progress: { _ in })
        #expect(try String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "Hello, wörld!\nSecond line.")

        _ = try await converter.convert(rtf, from: .rtf, to: .pdf, output: pdf, options: .init(), progress: { _ in })
        let document = try #require(PDFDocument(url: pdf))
        #expect(document.string?.contains("Hello") == true)
    }

    @Test @MainActor func markdownBecomesFormattedText() throws {
        let html = Markdown.html(from: "# Title\n\nSome **bold** and *italic* with `code`.\n\n- one\n- two\n\n1. first\n")
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<b>bold</b>"))
        #expect(html.contains("<i>italic</i>"))
        #expect(html.contains("<ul>\n<li>one</li>\n<li>two</li>\n</ul>"))
        #expect(html.contains("<ol>\n<li>first</li>\n</ol>"))
        let text = try DocumentConverter.read(Data("# Title\n\nBody".utf8), as: .markdown)
        #expect(text.string.contains("Title"))
        #expect(text.string.contains("Body"))
    }

    @Test func outputNamerNeverOverwrites() throws {
        let input = dir.appendingPathComponent("report.csv")
        let first = OutputNamer.uniqueURL(for: input, ext: "json", in: dir)
        #expect(first.lastPathComponent == "report.json")
        try Data().write(to: first)
        #expect(OutputNamer.uniqueURL(for: input, ext: "json", in: dir).lastPathComponent == "report (1).json")
        try Data().write(to: dir.appendingPathComponent("report (1).json"))
        #expect(OutputNamer.uniqueURL(for: input, ext: "json", in: dir).lastPathComponent == "report (2).json")
    }

    @Test func formatDetection() {
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.JPG")) == .jpeg)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.tif")) == .tiff)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.markdown")) == .markdown)
        #expect(FileFormat.detect(URL(fileURLWithPath: "/a/b.unknownext")) == nil)
    }
}

struct RegistryTests {
    @Test func prefersNativeConverters() {
        let fake = FFmpegConverter(executable: URL(fileURLWithPath: "/nonexistent/ffmpeg"),
                                   encoders: ["libx264", "aac", "libmp3lame", "libvpx-vp9", "libopus", "libwebp", "gif", "pcm_s16le", "pcm_s16be", "flac", "libvorbis", "mpeg4"])
        let registry = ConverterRegistry(converters: ConverterRegistry.standard(ffmpeg: nil).converters + [fake])
        #expect(registry.converter(from: .mov, to: .mp4) is AVConverter)
        #expect(registry.converter(from: .png, to: .jpeg) is ImageConverter)
        #expect(registry.converter(from: .mov, to: .webm) is FFmpegConverter)
        #expect(registry.converter(from: .wav, to: .mp3) is FFmpegConverter)
        #expect(registry.targets(for: .mkv).contains(.mp4))
    }

    @Test func ffmpegOnlyTargetsNeedFFmpeg() {
        let native = ConverterRegistry.standard(ffmpeg: nil)
        #expect(!native.targets(for: .mov).contains(.webm))
        #expect(native.targets(for: .mkv).isEmpty)
        #expect(native.targets(for: .csv) == [.json, .xlsx])
    }

    @Test func missingEncodersHideTargets() {
        let limited = FFmpegConverter(executable: URL(fileURLWithPath: "/x"), encoders: ["aac", "libx264"])
        let targets = limited.targets(for: .mkv)
        #expect(targets.contains(.mp4))
        #expect(!targets.contains(.webm))
        #expect(!targets.contains(.mp3))
    }
}
