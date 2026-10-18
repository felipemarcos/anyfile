import AppKit
import Foundation

/// SVG → raster images or vector PDF, rendered by macOS's own SVG engine (via NSImage).
/// MuPDF's SVG reader drops clip paths on gradients, so it isn't used for this direction.
struct SVGConverter: Converter {
    /// Raster output is rendered at 2× the SVG's size (like 144 dpi for PDF pages).
    static let scale: CGFloat = 2

    func targets(for input: FileFormat) -> [FileFormat] {
        input == .svg ? [.png, .jpeg, .heic, .tiff, .gif, .bmp, .pdf] : []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard let image = NSImage(contentsOf: input), image.isValid, image.size.width > 0, image.size.height > 0 else {
            throw ConversionError("Couldn't read the SVG.")
        }
        let size = image.size

        if target == .pdf {
            // Drawing the SVG into a PDF context keeps it vector.
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(output as CFURL, mediaBox: &box, nil) else {
                throw ConversionError("Couldn't create the PDF.")
            }
            ctx.beginPDFPage(nil)
            draw(image, in: ctx, size: size)
            ctx.endPDFPage()
            ctx.closePDF()
        } else {
            let width = Int((size.width * Self.scale).rounded())
            let height = Int((size.height * Self.scale).rounded())
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ConversionError("Couldn't render the SVG.")
            }
            // Formats without transparency get a white background.
            if target == .jpeg || target == .bmp {
                ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.scaleBy(x: Self.scale, y: Self.scale)
            draw(image, in: ctx, size: size)
            guard let rendered = ctx.makeImage() else { throw ConversionError("Couldn't render the SVG.") }
            try PDFConverter.write(rendered, as: target, to: output, quality: options.imageQuality)
        }
        progress(1)
        return output
    }

    private func draw(_ image: NSImage, in ctx: CGContext, size: CGSize) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
}
