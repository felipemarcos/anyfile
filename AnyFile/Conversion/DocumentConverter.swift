import AppKit
import Foundation

/// Text document conversion via NSAttributedString's importers and exporters.
struct DocumentConverter: Converter {
    static let inputs: Set<FileFormat> = [.txt, .rtf, .docx, .html, .odt, .markdown]
    static let outputs: [FileFormat] = [.txt, .rtf, .docx, .html, .odt, .pdf]

    func targets(for input: FileFormat) -> [FileFormat] {
        Self.inputs.contains(input) ? Self.outputs : []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        let data = try Data(contentsOf: input)
        // The HTML importer uses WebKit and the PDF exporter uses NSTextView; both need the main thread.
        try await MainActor.run {
            let text = try Self.read(data, as: source)
            progress(0.5)
            if target == .pdf {
                try Self.writePDF(text, to: output)
            } else {
                try Self.write(text, as: target).write(to: output, options: .atomic)
            }
        }
        progress(1)
        return output
    }

    @MainActor
    static func read(_ data: Data, as format: FileFormat) throws -> NSAttributedString {
        if format == .markdown {
            let markdown = String(decoding: data, as: UTF8.self)
            return try read(Data(Markdown.html(from: markdown).utf8), as: .html)
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type = documentType(for: format) { options[.documentType] = type }
        if format == .html || format == .txt { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }

    @MainActor
    static func write(_ text: NSAttributedString, as format: FileFormat) throws -> Data {
        guard let type = documentType(for: format) else {
            throw ConversionError("Can't write \(format.displayName).")
        }
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if format == .html || format == .txt { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
        return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
    }

    /// Lays the text out on Letter/A4 pages (per locale) with 1-inch margins.
    @MainActor
    static func writePDF(_ text: NSAttributedString, to output: URL) throws {
        let printInfo = NSPrintInfo()
        let usesMetric = Locale.current.measurementSystem != .us
        printInfo.paperSize = usesMetric ? NSSize(width: 595, height: 842) : NSSize(width: 612, height: 792)
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let height = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 1
        textView.setFrameSize(NSSize(width: width, height: max(height, 1)))

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError("Couldn't create the PDF.")
        }
    }

    static func documentType(for format: FileFormat) -> NSAttributedString.DocumentType? {
        switch format {
        case .txt: .plain
        case .rtf: .rtf
        case .docx: .officeOpenXML
        case .html: .html
        case .odt: .openDocument
        default: nil
        }
    }
}
