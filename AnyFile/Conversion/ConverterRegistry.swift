import Foundation

/// Routes a (source, target) pair to the first converter that supports it.
/// Native converters come first, so ffmpeg is used only for what Apple's frameworks can't do.
struct ConverterRegistry: Sendable {
    let converters: [any Converter]

    static func standard(ffmpeg: URL? = FFmpegLocator.find(), mutool: URL? = MuPDFLocator.find()) -> ConverterRegistry {
        var converters: [any Converter] = [
            ImageConverter(),
            SVGConverter(),
            AVConverter(),
            DocumentConverter(),
            PDFConverter(),
            DataConverter(),
        ]
        if let mutool {
            converters.append(MuPDFConverter(executable: mutool))
        }
        if let ffmpeg {
            converters.append(FFmpegConverter(executable: ffmpeg))
        }
        return ConverterRegistry(converters: converters)
    }

    /// All formats `source` can be converted to, in a stable order, excluding itself.
    func targets(for source: FileFormat) -> [FileFormat] {
        let all = Set(converters.flatMap { $0.targets(for: source) })
        return FileFormat.allCases.filter { all.contains($0) && $0 != source }
    }

    func converter(from source: FileFormat, to target: FileFormat) -> (any Converter)? {
        converters.first { $0.targets(for: source).contains(target) }
    }
}
