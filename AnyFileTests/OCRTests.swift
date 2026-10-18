import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import AnyFile

struct OCRTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A 300 dpi "scan" of a US Letter page: black text lines on white, as a bitmap.
    private func scanImage(_ lines: [String]) -> CGImage {
        let width = 2550, height = 3300
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont(name: "Helvetica", size: 64)!, .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 300, y: 2900 - i * 160))
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    /// A PDF whose pages are images only (no text layer), or real text where `textPages` says so.
    private func makePDF(_ name: String, pages: [[String]], textPages: Set<Int> = []) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for (index, lines) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            if textPages.contains(index) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                NSAttributedString(string: lines.joined(separator: "\n"), attributes: [.font: NSFont(name: "Helvetica", size: 16)!])
                    .draw(at: CGPoint(x: 72, y: 600))
                NSGraphicsContext.restoreGraphicsState()
            } else {
                ctx.draw(scanImage(lines), in: box)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    private func convert(_ input: URL, _ source: FileFormat, to target: FileFormat, _ name: String,
                         options: ConversionOptions = .init()) async throws -> URL {
        let out = dir.appendingPathComponent(name)
        let converter = try #require(ConverterRegistry.standard(ffmpeg: nil).converter(from: source, to: target))
        return try await converter.convert(input, from: source, to: target, output: out, options: options, progress: { _ in })
    }

    @Test func scannedPDFBecomesSearchableAndLooksTheSame() async throws {
        let scan = try makePDF("scan.pdf", pages: [["Invoice number 4821", "Total due: 1,250.00 USD"]])
        #expect(TextRecognizer.needsOCR(try #require(PDFDocument(url: scan)?.page(at: 0))))

        let out = try await convert(scan, .pdf, to: .searchablePDF, "scan-ocr.pdf")
        let document = try #require(PDFDocument(url: out))
        let text = try #require(document.string)
        #expect(text.contains("Invoice"))
        #expect(text.contains("4821"))
        #expect(text.contains("1,250.00"))

        // The word is found where it's drawn: line 1 starts at x=300px/300dpi*72 ≈ 72pt, near the top.
        let hit = try #require(document.findString("Invoice", withOptions: .caseInsensitive).first)
        let bounds = hit.bounds(for: try #require(document.page(at: 0)))
        #expect(abs(bounds.minX - 72) < 12)
        #expect(bounds.minY > 680 && bounds.maxY < 730)

        // Invisible text: the page renders the same as the original.
        let before = try PDFConverter.render(try #require(PDFDocument(url: scan)?.page(at: 0)), dpi: 36, flattenOnWhite: true)
        let after = try PDFConverter.render(try #require(document.page(at: 0)), dpi: 36, flattenOnWhite: true)
        #expect(difference(before, after) < 4)
    }

    @Test func recognizesPortugueseAccents() async throws {
        let scan = try makePDF("pt.pdf", pages: [["Conversão de arquivos é rápida", "Atenção: não há envio"]])
        let out = try await convert(scan, .pdf, to: .searchablePDF, "pt-ocr.pdf", options: .init(ocrLanguage: "pt-BR"))
        let text = try #require(PDFDocument(url: out)?.string)
        #expect(text.contains("Conversão"))
        #expect(text.contains("rápida"))
        #expect(text.contains("Atenção"))
    }

    @Test func pagesWithTextAreKeptAndOnlyScansAreOCRed() async throws {
        let mixed = try makePDF("mixed.pdf", pages: [["Typed page text"], ["Scanned page text"]], textPages: [0])
        let out = try await convert(mixed, .pdf, to: .searchablePDF, "mixed-ocr.pdf")
        let document = try #require(PDFDocument(url: out))
        #expect(document.pageCount == 2)
        #expect(document.page(at: 0)?.string?.contains("Typed page text") == true)
        #expect(document.page(at: 1)?.string?.contains("Scanned") == true)
    }

    @Test func alreadySearchablePDFIsRejected() async throws {
        let typed = try makePDF("typed.pdf", pages: [["Hello"]], textPages: [0])
        await #expect(throws: ConversionError.self) {
            _ = try await convert(typed, .pdf, to: .searchablePDF, "typed-ocr.pdf")
        }
    }

    @Test func pdfToTextFallsBackToOCRUnlessTurnedOff() async throws {
        let scan = try makePDF("scan2.pdf", pages: [["First scanned page"], ["Second scanned page"]])
        let on = try await convert(scan, .pdf, to: .txt, "on.txt")
        let text = try String(contentsOf: on, encoding: .utf8)
        #expect(text.contains("First scanned page"))
        #expect(text.contains("\u{0C}")) // page separator
        #expect(text.contains("Second scanned page"))

        let off = try await convert(scan, .pdf, to: .txt, "off.txt", options: .init(ocrScannedPages: false))
        #expect(try String(contentsOf: off, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{0C}"))).isEmpty)
    }

    @Test func imagesBecomeTextAndSearchablePDF() async throws {
        let png = dir.appendingPathComponent("photo.png")
        let dest = try #require(CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, scanImage(["Receipt 2026-10-18", "Coffee 4.50"]),
                                   [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let txt = try await convert(png, .png, to: .txt, "photo.txt")
        let text = try String(contentsOf: txt, encoding: .utf8)
        #expect(text.contains("Receipt"))
        #expect(text.contains("Coffee"))
        // Reading order: top line first.
        #expect(text.range(of: "Receipt")!.lowerBound < text.range(of: "Coffee")!.lowerBound)

        let pdf = try await convert(png, .png, to: .searchablePDF, "photo-ocr.pdf")
        let document = try #require(PDFDocument(url: pdf))
        // 2550×3300 px at 300 dpi = US Letter.
        #expect(document.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect(document.string?.contains("Coffee") == true)
    }

    @Test func rotatedPagesRenderUpright() async throws {
        let url = dir.appendingPathComponent("rot.pdf")
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        let document = try #require(PDFDocument(url: url))
        document.page(at: 0)?.rotation = 90
        let image = try PDFConverter.render(try #require(document.page(at: 0)), dpi: 72, flattenOnWhite: true)
        #expect(image.width == 100 && image.height == 200)
    }

    @Test func outputIsNamedWithOCRSuffix() throws {
        let input = dir.appendingPathComponent("scan.pdf")
        let url = OutputNamer.uniqueURL(for: input, ext: FileFormat.searchablePDF.fileExtension,
                                        suffix: FileFormat.searchablePDF.outputNameSuffix, in: dir)
        #expect(url.lastPathComponent == "scan (OCR).pdf")
        #expect(FileFormat.detect(input) == .pdf)
        #expect(ConverterRegistry.standard(ffmpeg: nil).targets(for: .pdf).contains(.searchablePDF))
        #expect(ConverterRegistry.standard(ffmpeg: nil).targets(for: .heic).contains(.txt))
    }

    /// Mean absolute RGB difference per channel, 0…255.
    private func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func bytes(_ image: CGImage) -> [UInt8] {
            let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let x = bytes(a), y = bytes(b)
        guard x.count == y.count else { return .infinity }
        return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
    }
}
