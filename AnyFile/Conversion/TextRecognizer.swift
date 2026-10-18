import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// On-device OCR with Apple's Vision framework.
enum TextRecognizer {
    struct Line {
        let text: String
        /// Normalized (0…1) box in the image, origin at the bottom-left.
        let box: CGRect
    }

    /// Resolution pages are rasterized at for recognition.
    static let ocrDPI: Double = 300

    /// Languages Vision can recognize on this Mac (BCP 47 codes such as "en-US", "pt-BR").
    static var supportedLanguages: [String] {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }

    /// Recognizes text lines in an image. `language` nil means automatic detection.
    static func recognize(_ image: CGImage, language: String?) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language {
            request.recognitionLanguages = [language]
            request.automaticallyDetectsLanguage = false
        } else {
            request.automaticallyDetectsLanguage = true
        }
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : Line(text: text, box: observation.boundingBox)
        }
    }

    /// Plain text of recognized lines, top to bottom.
    static func text(of lines: [Line]) -> String {
        lines.sorted { $0.box.midY != $1.box.midY ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
            .map(\.text).joined(separator: "\n")
    }

    /// True when a PDF page carries no real text and is worth OCRing.
    static func needsOCR(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// OCRs a PDF page by rendering it at `ocrDPI`.
    static func recognize(_ page: PDFPage, language: String?) throws -> [Line] {
        try recognize(PDFConverter.render(page, dpi: ocrDPI, flattenOnWhite: true), language: language)
    }

    /// Draws recognized lines as invisible text over a page of `size` points, so the page can be
    /// selected, copied and searched while looking unchanged. Each line is stretched to its box.
    static func drawInvisibleText(_ lines: [Line], in ctx: CGContext, pageSize size: CGSize) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let box = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                             width: line.box.width * size.width, height: line.box.height * size.height)
            guard box.width > 1, box.height > 1 else { continue }
            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.8, nil)
            let attributed = NSAttributedString(string: line.text, attributes: [.init(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            guard width > 0 else { continue }
            ctx.textMatrix = CGAffineTransform(scaleX: box.width / width, y: 1)
            ctx.textPosition = CGPoint(x: box.minX, y: box.minY + (box.height - ascent - descent) / 2 + descent)
            CTLineDraw(ctLine, ctx)
        }
        ctx.restoreGState()
    }
}
