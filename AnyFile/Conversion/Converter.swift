import Foundation

/// User-tunable settings that affect conversion output.
struct ConversionOptions: Sendable {
    /// Lossy image quality, 0...1 (JPEG, HEIC).
    var imageQuality: Double = 0.85
    /// Pixel density when vector sources (PDF pages, Illustrator, SVG) become raster images.
    /// 72 dpi = 1 pixel per point.
    var renderDPI: Double = 144
    /// When converting XLSX to JSON, export every sheet keyed by sheet name instead of only the first.
    var allSheets: Bool = false
    /// Run generated SVGs through SVGO (SVGOMG's engine).
    var optimizeSVG: Bool = true
}

typealias ProgressHandler = @Sendable (Double) -> Void

protocol Converter: Sendable {
    /// Formats this converter can produce from `input`. Empty when it can't read `input`.
    func targets(for input: FileFormat) -> [FileFormat]

    /// Converts `input` to `target`, writing to `output`.
    /// Returns the URL actually written (a folder when one input produces several files).
    func convert(
        _ input: URL,
        from source: FileFormat,
        to target: FileFormat,
        output: URL,
        options: ConversionOptions,
        progress: @escaping ProgressHandler
    ) async throws -> URL
}

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
