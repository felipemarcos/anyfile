import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// OCR outputs: searchable PDFs (from PDFs or images) and text from images.
/// PDF → TXT uses OCR too, inside PDFConverter, for pages without a text layer.
struct OCRConverter: Converter {
    static let imageInputs: Set<FileFormat> = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webp]

    func targets(for input: FileFormat) -> [FileFormat] {
        if input == .pdf || input == .ai { return [.searchablePDF] }
        if Self.imageInputs.contains(input) { return [.searchablePDF, .txt] }
        return []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        switch (source, target) {
        case (.pdf, .searchablePDF), (.ai, .searchablePDF):
            try searchablePDF(fromPDF: input, source: source, output: output, options: options, progress: progress)
        case (_, .searchablePDF):
            try searchablePDF(fromImage: input, output: output, options: options, progress: progress)
        case (_, .txt):
            let (image, _) = try Self.loadImage(input)
            let text = TextRecognizer.text(of: try TextRecognizer.recognize(image, language: options.ocrLanguage))
            guard !text.isEmpty else { throw ConversionError("No text was found in the image.") }
            try Data((text + "\n").utf8).write(to: output, options: .atomic)
        default:
            throw ConversionError("Can't convert \(source.displayName) to \(target.displayName).")
        }
        progress(1)
        return output
    }

    /// Redraws every page unchanged (vector content stays vector) and adds an invisible text layer
    /// to pages that have no text. Pages that already have text are copied as they are.
    private func searchablePDF(fromPDF input: URL, source: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) throws {
        guard let document = PDFDocument(url: input) else {
            throw ConversionError(source == .ai
                ? "This Illustrator file was saved without PDF compatibility. Re-save it in Illustrator with \"Create PDF Compatible File\" on."
                : "Couldn't open the PDF.")
        }
        guard !document.isLocked else { throw ConversionError("The PDF is password-protected.") }
        guard document.pageCount > 0 else { throw ConversionError("The PDF has no pages.") }

        let pagesToOCR = (0..<document.pageCount).filter { document.page(at: $0).map(TextRecognizer.needsOCR) ?? false }
        guard !pagesToOCR.isEmpty else {
            throw ConversionError("This PDF is already searchable: every page has text.")
        }

        let ctx = try Self.pdfContext(output, attributes: document.documentAttributes)
        var recognizedAny = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let size = PDFConverter.displaySize(of: page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.saveGState()
            PDFConverter.drawUpright(page, in: ctx)
            ctx.restoreGState()
            if TextRecognizer.needsOCR(page) {
                let lines = try TextRecognizer.recognize(page, language: options.ocrLanguage)
                TextRecognizer.drawInvisibleText(lines, in: ctx, pageSize: size)
                recognizedAny = recognizedAny || !lines.isEmpty
            }
            ctx.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        ctx.closePDF()
        guard recognizedAny else { throw ConversionError("No text was found in the scanned pages.") }
    }

    /// One page per image frame, sized from the image's DPI (72 if it has none).
    private func searchablePDF(fromImage input: URL, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError("Couldn't open the image.")
        }
        let frames = CGImageSourceGetCount(source)
        let ctx = try Self.pdfContext(output, attributes: nil)
        for index in 0..<frames {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let dpi = (props?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
            let size = CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            TextRecognizer.drawInvisibleText(try TextRecognizer.recognize(image, language: options.ocrLanguage), in: ctx, pageSize: size)
            ctx.endPage()
            progress(Double(index + 1) / Double(frames))
        }
        ctx.closePDF()
    }

    static func pdfContext(_ url: URL, attributes: [AnyHashable: Any]?) throws -> CGContext {
        var info: [CFString: Any] = [kCGPDFContextCreator: "AnyFile"]
        if let title = attributes?[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle] = title }
        if let author = attributes?[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor] = author }
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        return ctx
    }

    static func loadImage(_ url: URL) throws -> (CGImage, Double) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError("Couldn't open the image.")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (image, props?[kCGImagePropertyDPIWidth] as? Double ?? 72)
    }
}
