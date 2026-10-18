import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Raster image conversion with ImageIO.
struct ImageConverter: Converter {
    static let inputs: Set<FileFormat> = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webp]
    static let outputs: [FileFormat] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .pdf]

    func targets(for input: FileFormat) -> [FileFormat] {
        Self.inputs.contains(input) ? Self.outputs : []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ConversionError("Couldn't open the image.")
        }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 0 else { throw ConversionError("The image has no frames.") }

        if target == .pdf {
            try writePDF(from: imageSource, frameCount: frameCount, to: output)
        } else {
            try writeImage(from: imageSource, to: target, output: output, quality: options.imageQuality)
        }
        progress(1)
        return output
    }

    private func writeImage(from source: CGImageSource, to target: FileFormat, output: URL, quality: Double) throws {
        guard var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError("Couldn't decode the image.")
        }
        // Formats without alpha get a white background instead of black.
        if target == .jpeg || target == .bmp, image.hasAlpha {
            image = try Self.flattened(image)
        }
        guard let type = Self.utType(for: target),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError("\(target.displayName) output isn't supported on this Mac.")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if target == .jpeg || target == .heic {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError("Couldn't write the \(target.displayName) file.")
        }
    }

    /// Every frame becomes one page sized to the image (72 dpi).
    private func writePDF(from source: CGImageSource, frameCount: Int, to output: URL) throws {
        guard let consumer = CGDataConsumer(url: output as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        for index in 0..<frameCount {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    static func utType(for format: FileFormat) -> UTType? {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .webp: .webP
        case .pdf: .pdf
        default: nil
        }
    }

    static func flattened(_ image: CGImage) throws -> CGImage {
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ConversionError("Couldn't process the image.") }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError("Couldn't process the image.") }
        return result
    }
}

private extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}
