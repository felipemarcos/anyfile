import AppKit
import Foundation
import PDFKit
import Testing
@testable import AnyFile

struct SVGConverterTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self) + ((image.height - 1 - y) * image.width + x) * 4
        return (p[0], p[1], p[2], p[3])
    }

    private func load(_ url: URL) throws -> CGImage {
        try #require(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    /// Regression: a gradient-filled square clipped to a circle must stay a circle
    /// (MuPDF's SVG reader drew the whole square).
    @Test func clippedGradientKeepsItsShape() async throws {
        let svg = dir.appendingPathComponent("clip.svg")
        try Data(##"""
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">
          <defs>
            <clipPath id="c"><circle cx="50" cy="50" r="30"/></clipPath>
            <linearGradient id="g"><stop offset="0" stop-color="#00f"/><stop offset="1" stop-color="#0ff"/></linearGradient>
          </defs>
          <rect width="100" height="100" fill="url(#g)" clip-path="url(#c)"/>
        </svg>
        """##.utf8).write(to: svg)
        let png = dir.appendingPathComponent("clip.png")
        _ = try await SVGConverter().convert(svg, from: .svg, to: .png, output: png, options: .init(), progress: { _ in })
        let image = try load(png)
        #expect(image.width == 200 && image.height == 200)
        #expect(pixel(image, x: 100, y: 100).3 == 255) // centre: inside the circle, opaque
        #expect(pixel(image, x: 10, y: 10).3 == 0)     // corner: clipped away, transparent
    }

    @Test func jpegGetsWhiteBackgroundAndPDFStaysVector() async throws {
        let svg = dir.appendingPathComponent("dot.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20"><circle cx="10" cy="10" r="8" fill="#c00"/></svg>"##.utf8).write(to: svg)
        let jpg = dir.appendingPathComponent("dot.jpg")
        let pdf = dir.appendingPathComponent("dot.pdf")
        _ = try await SVGConverter().convert(svg, from: .svg, to: .jpeg, output: jpg, options: .init(), progress: { _ in })
        _ = try await SVGConverter().convert(svg, from: .svg, to: .pdf, output: pdf, options: .init(), progress: { _ in })
        let corner = pixel(try load(jpg), x: 78, y: 2)
        #expect(corner.0 > 240 && corner.1 > 240 && corner.2 > 240)
        let page = try #require(PDFDocument(url: pdf)?.page(at: 0))
        #expect(page.bounds(for: .mediaBox).size == CGSize(width: 40, height: 20))
        // A vector page has no embedded raster image.
        let raw = try String(decoding: Data(contentsOf: pdf), as: UTF8.self)
        #expect(!raw.contains("/Subtype /Image"))
    }

    @Test func rejectsBrokenSVG() async throws {
        let svg = dir.appendingPathComponent("broken.svg")
        try Data("not svg".utf8).write(to: svg)
        await #expect(throws: ConversionError.self) {
            _ = try await SVGConverter().convert(svg, from: .svg, to: .png, output: dir.appendingPathComponent("b.png"), options: .init(), progress: { _ in })
        }
    }
}
