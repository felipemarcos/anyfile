import Foundation
import UniformTypeIdentifiers

enum FormatCategory: String, CaseIterable, Sendable {
    case image = "Image"
    case video = "Video"
    case audio = "Audio"
    case document = "Document"
    case pdf = "PDF"
    case data = "Data"
}

/// Every file format AnyFile knows how to read or write.
enum FileFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    // Images
    case png, jpeg, heic, tiff, gif, bmp, webp, svg
    // Video
    case mp4, mov, m4v, webm, mkv, avi
    // Audio
    case m4a, wav, aiff, caf, mp3, flac, ogg, opus, aac
    // Documents
    case txt, rtf, docx, html, odt, markdown
    // PDF and vector documents
    case pdf, ai
    // Data
    case json, plist, csv, xlsx

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .markdown: "md"
        default: rawValue
        }
    }

    var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .docx: "Word (DOCX)"
        case .odt: "OpenDocument (ODT)"
        case .xlsx: "Excel (XLSX)"
        case .ai: "Illustrator (AI)"
        case .txt: "Plain Text"
        default: rawValue.uppercased()
        }
    }

    var category: FormatCategory {
        switch self {
        case .png, .jpeg, .heic, .tiff, .gif, .bmp, .webp, .svg: .image
        case .mp4, .mov, .m4v, .webm, .mkv, .avi: .video
        case .m4a, .wav, .aiff, .caf, .mp3, .flac, .ogg, .opus, .aac: .audio
        case .txt, .rtf, .docx, .html, .odt, .markdown: .document
        case .pdf, .ai: .pdf
        case .json, .plist, .csv, .xlsx: .data
        }
    }

    var symbolName: String {
        switch category {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.text"
        case .pdf: "doc.richtext"
        case .data: "tablecells"
        }
    }

    /// Extra extensions that map to this format when reading.
    private var aliases: [String] {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe"]
        case .tiff: ["tif", "tiff"]
        case .heic: ["heic", "heif"]
        case .aiff: ["aif", "aiff"]
        case .html: ["html", "htm"]
        case .markdown: ["md", "markdown"]
        case .txt: ["txt", "text"]
        case .ogg: ["ogg", "oga"]
        default: [fileExtension]
        }
    }

    var utType: UTType? {
        switch self {
        case .ai: UTType("com.adobe.illustrator.ai-image") ?? UTType(filenameExtension: "ai")
        default: UTType(filenameExtension: fileExtension)
        }
    }

    /// Detects a format from a file's extension, falling back to its content type.
    static func detect(_ url: URL) -> FileFormat? {
        let ext = url.pathExtension.lowercased()
        if let match = allCases.first(where: { $0.aliases.contains(ext) }) {
            return match
        }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        return allCases.first { format in
            guard let formatType = format.utType else { return false }
            return type.conforms(to: formatType)
        }
    }
}
