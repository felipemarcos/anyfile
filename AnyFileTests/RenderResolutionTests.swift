import AppKit
import Foundation
import ImageIO
import Testing
@testable import AnyFile

struct RenderResolutionTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// (width, height, dpi) as stored in the file.
    private func info(_ url: URL) throws -> (Int, Int, Double) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0,
                props[kCGImagePropertyDPIWidth] as? Double ?? 0)
    }

    private func letterPDF() throws -> URL {
        let url = dir.appendingPathComponent("letter.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 72, y: 72, width: 200, height: 200))
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @Test(arguments: [(72.0, 612, 792), (144, 1224, 1584), (300, 2550, 3300), (600, 5100, 6600)])
    func pdfPagesFollowTheSetting(dpi: Double, width: Int, height: Int) async throws {
        let pdf = try letterPDF()
        let png = dir.appendingPathComponent("page-\(Int(dpi)).png")
        _ = try await PDFConverter().convert(pdf, from: .pdf, to: .png, output: png, options: .init(renderDPI: dpi), progress: { _ in })
        let (w, h, storedDPI) = try info(png)
        #expect(w == width && h == height)
        #expect(storedDPI == dpi)
    }

    @Test(arguments: [(72.0, 50), (216, 150), (288, 200)])
    func svgFollowsTheSetting(dpi: Double, width: Int) async throws {
        let svg = dir.appendingPathComponent("s.svg")
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="50" height="25"><rect width="50" height="25" fill="#09f"/></svg>"##.utf8).write(to: svg)
        let jpg = dir.appendingPathComponent("s-\(Int(dpi)).jpg")
        _ = try await SVGConverter().convert(svg, from: .svg, to: .jpeg, output: jpg, options: .init(renderDPI: dpi), progress: { _ in })
        let (w, h, _) = try info(jpg)
        #expect(w == width && h == width / 2)
    }

    @Test @MainActor func settingPersistsAndReachesOptions() {
        let defaults = UserDefaults(suiteName: "AnyFileTests-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.renderDPI == 144)
        settings.renderDPI = 300
        #expect(settings.options.renderDPI == 300)
        #expect(AppSettings(defaults: defaults).renderDPI == 300)
        #expect(AppSettings.renderDPIPresets.contains { $0.0 == 144 })
    }
}
