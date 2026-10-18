import AppKit
import Foundation
import PDFKit
import Testing
@testable import AnyFile

@Suite(.enabled(if: MuPDFLocator.find() != nil, "needs mutool"))
struct MuPDFTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")
    let converter = MuPDFConverter(executable: MuPDFLocator.find()!)

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A PDF with `pages` pages, each with a filled rectangle and some text.
    private func makePDF(_ name: String, pages: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 1...pages {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(srgbRed: 0.4, green: 0.3, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 20, y: 20, width: 120, height: 80))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSAttributedString(string: "Page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 24)])
                .draw(at: CGPoint(x: 160, y: 140))
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    @Test func singlePagePDFToSVG() async throws {
        let pdf = try makePDF("one.pdf", pages: 1)
        let out = dir.appendingPathComponent("one.svg")
        let written = try await converter.convert(pdf, from: .pdf, to: .svg, output: out, options: .init(), progress: { _ in })
        #expect(written == out)
        let svg = try String(contentsOf: out, encoding: .utf8)
        #expect(svg.contains("<svg"))
        #expect(svg.contains(#"viewBox="0 0 300 200""#))
        #expect(svg.contains("<path")) // rectangle and text outlines
    }

    @Test func svgOutputIsOptimizedUnlessTurnedOff() async throws {
        let pdf = try makePDF("opt.pdf", pages: 1)
        let raw = dir.appendingPathComponent("raw.svg")
        let optimized = dir.appendingPathComponent("optimized.svg")
        _ = try await converter.convert(pdf, from: .pdf, to: .svg, output: raw, options: .init(optimizeSVG: false), progress: { _ in })
        _ = try await converter.convert(pdf, from: .pdf, to: .svg, output: optimized, options: .init(optimizeSVG: true), progress: { _ in })
        let rawSize = try Data(contentsOf: raw).count
        let optimizedSize = try Data(contentsOf: optimized).count
        #expect(optimizedSize < rawSize)
        let svg = try String(contentsOf: optimized, encoding: .utf8)
        #expect(svg.contains("viewBox=\"0 0 300 200\""))
        #expect(!svg.contains("xmlns:inkscape"))
    }

    @Test func multiPagePDFMakesAFolder() async throws {
        let pdf = try makePDF("deck.pdf", pages: 3)
        let out = dir.appendingPathComponent("deck.svg")
        let written = try await converter.convert(pdf, from: .pdf, to: .svg, output: out, options: .init(), progress: { _ in })
        #expect(written.lastPathComponent == "deck")
        let files = try FileManager.default.contentsOfDirectory(atPath: written.path).sorted()
        #expect(files == ["deck-1.svg", "deck-2.svg", "deck-3.svg"])
    }

    @Test func illustratorFilesConvertLikePDFs() async throws {
        // Illustrator's default "PDF compatible" files are PDFs with an .ai extension.
        let pdf = try makePDF("logo.pdf", pages: 1)
        let ai = dir.appendingPathComponent("logo.ai")
        try FileManager.default.copyItem(at: pdf, to: ai)
        #expect(FileFormat.detect(ai) == .ai)

        let svg = dir.appendingPathComponent("logo.svg")
        _ = try await converter.convert(ai, from: .ai, to: .svg, output: svg, options: .init(), progress: { _ in })
        #expect(try String(contentsOf: svg, encoding: .utf8).contains("<svg"))

        let pdfOut = dir.appendingPathComponent("logo-out.pdf")
        _ = try await PDFConverter().convert(ai, from: .ai, to: .pdf, output: pdfOut, options: .init(), progress: { _ in })
        #expect(PDFDocument(url: pdfOut)?.pageCount == 1)
    }

    @Test func legacyIllustratorFileGivesClearError() async throws {
        let ai = dir.appendingPathComponent("old.ai")
        try Data("%!PS-Adobe-3.0\n%%Creator: Adobe Illustrator 8\n".utf8).write(to: ai)
        await #expect(throws: ConversionError.self) {
            _ = try await converter.convert(ai, from: .ai, to: .svg, output: dir.appendingPathComponent("old.svg"), options: .init(), progress: { _ in })
        }
    }

    @Test func pdfToHTMLKeepsLayoutBoldAndImages() async throws {
        let url = dir.appendingPathComponent("styled.pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let text = NSMutableAttributedString(string: "Plain ", attributes: [.font: NSFont(name: "Helvetica", size: 18)!])
        text.append(NSAttributedString(string: "Strong", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 18)!]))
        text.append(NSAttributedString(string: " & <tail>", attributes: [.font: NSFont(name: "Times-Italic", size: 18)!]))
        text.draw(at: CGPoint(x: 40, y: 240))
        NSGraphicsContext.restoreGraphicsState()
        let pixel = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        pixel.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        pixel.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.draw(pixel.makeImage()!, in: CGRect(x: 40, y: 40, width: 80, height: 80))
        ctx.endPDFPage()
        ctx.closePDF()

        let out = dir.appendingPathComponent("styled.html")
        _ = try await converter.convert(url, from: .pdf, to: .html, output: out, options: .init(), progress: { _ in })
        let html = try String(contentsOf: out, encoding: .utf8)
        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(html.contains("<title>styled</title>"))
        #expect(html.contains("position:absolute") || html.contains("position:relative"))
        #expect(html.contains("data:image/"))
        let strong = try #require(html.range(of: #"<span style="[^"]*">Strong</span>"#, options: .regularExpression))
        #expect(html[strong].contains("font-weight:bold"))
        let plain = try #require(html.range(of: #"<span style="[^"]*">Plain\s*</span>"#, options: .regularExpression))
        #expect(!html[plain].contains("font-weight:bold"))
        #expect(html[plain].contains("sans-serif"))
        #expect(html.contains("font-style:italic"))
    }

    @Test func registryOffersSVG() {
        let registry = ConverterRegistry.standard(ffmpeg: nil)
        #expect(registry.targets(for: .pdf).contains(.svg))
        #expect(registry.targets(for: .ai).contains(.svg))
        #expect(registry.targets(for: .pdf).contains(.html))
        #expect(registry.converter(from: .svg, to: .png) is SVGConverter)
    }
}
