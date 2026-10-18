import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// PDF (and PDF-compatible Illustrator files) → page images (one file per page), plain text, or PDF.
struct PDFConverter: Converter {
    func targets(for input: FileFormat) -> [FileFormat] {
        switch input {
        case .pdf: [.png, .jpeg, .tiff, .txt]
        case .ai: [.pdf, .png, .jpeg, .tiff, .txt]
        default: []
        }
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard let document = PDFDocument(url: input) else {
            throw ConversionError(source == .ai
                ? "This Illustrator file was saved without PDF compatibility. Re-save it in Illustrator with \"Create PDF Compatible File\" on."
                : "Couldn't open the PDF.")
        }
        if document.isLocked {
            throw ConversionError("The PDF is password-protected.")
        }

        if target == .pdf {
            guard document.write(to: output) else { throw ConversionError("Couldn't write the PDF.") }
            progress(1)
            return output
        }

        if target == .txt {
            // Pages without a text layer (scans) are OCRed when the setting allows it.
            var pages: [String] = []
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                if options.ocrScannedPages && TextRecognizer.needsOCR(page) {
                    pages.append(TextRecognizer.text(of: try TextRecognizer.recognize(page, language: options.ocrLanguage)))
                } else {
                    pages.append(page.string ?? "")
                }
                progress(Double(index + 1) / Double(max(document.pageCount, 1)))
            }
            // Form feed between pages, as pdftotext does.
            try Data(pages.joined(separator: "\n\u{0C}").utf8).write(to: output, options: .atomic)
            return output
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else { throw ConversionError("The PDF has no pages.") }

        // A single page becomes one image; several pages go into a folder.
        let folder: URL?
        if pageCount > 1 {
            let url = OutputNamer.uniqueURL(for: input, ext: "", in: output.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            folder = url
        } else {
            folder = nil
        }
        let base = input.deletingPathExtension().lastPathComponent
        let digits = String(pageCount).count

        do {
            for index in 0..<pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let image = try Self.render(page, dpi: options.renderDPI, flattenOnWhite: true)
                let pageURL: URL
                if let folder {
                    let number = String(index + 1).leftPadded(to: digits)
                    pageURL = folder.appendingPathComponent("\(base)-\(number)").appendingPathExtension(target.fileExtension)
                } else {
                    pageURL = output
                }
                try Self.write(image, as: target, to: pageURL, quality: options.imageQuality, dpi: options.renderDPI)
                progress(Double(index + 1) / Double(pageCount))
            }
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return folder ?? output
    }

    /// The page's size as displayed, in points: its media box with the page rotation applied.
    static func displaySize(of page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
        return quarterTurns % 2 == 1 ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    /// Draws the page upright into a context sized `displaySize(of:)`. PDFKit applies the
    /// rotation and media-box origin itself.
    static func drawUpright(_ page: PDFPage, in ctx: CGContext) {
        page.draw(with: .mediaBox, to: ctx)
    }

    static func render(_ page: PDFPage, dpi: Double, flattenOnWhite: Bool) throws -> CGImage {
        let size = displaySize(of: page)
        let scale = CGFloat(dpi / 72)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw ConversionError("Couldn't render the page.") }
        if flattenOnWhite {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.scaleBy(x: scale, y: scale)
        drawUpright(page, in: context)
        guard let image = context.makeImage() else { throw ConversionError("Couldn't render the page.") }
        return image
    }

    /// Writes a rendered image, recording `dpi` so it keeps its physical size when printed or placed.
    static func write(_ image: CGImage, as format: FileFormat, to url: URL, quality: Double, dpi: Double) throws {
        guard let type = ImageConverter.utType(for: format),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError("Can't write \(format.displayName).")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError("Couldn't write the image.")
        }
    }
}

private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: "0", count: length - count) + self
    }
}
