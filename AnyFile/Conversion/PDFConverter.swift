import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// PDF (and PDF-compatible Illustrator files) → page images (one file per page), plain text, or PDF.
struct PDFConverter: Converter {
    /// Render resolution for page images.
    static let dpi: CGFloat = 144

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
            let text = document.string ?? ""
            try Data(text.utf8).write(to: output, options: .atomic)
            progress(1)
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
                let image = try Self.render(page, flattenOnWhite: true)
                let pageURL: URL
                if let folder {
                    let number = String(index + 1).leftPadded(to: digits)
                    pageURL = folder.appendingPathComponent("\(base)-\(number)").appendingPathExtension(target.fileExtension)
                } else {
                    pageURL = output
                }
                try Self.write(image, as: target, to: pageURL, quality: options.imageQuality)
                progress(Double(index + 1) / Double(pageCount))
            }
        } catch {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            throw error
        }
        return folder ?? output
    }

    static func render(_ page: PDFPage, flattenOnWhite: Bool) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
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
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError("Couldn't render the page.") }
        return image
    }

    static func write(_ image: CGImage, as format: FileFormat, to url: URL, quality: Double) throws {
        guard let type = ImageConverter.utType(for: format),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError("Can't write \(format.displayName).")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
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
