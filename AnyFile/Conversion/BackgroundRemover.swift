import CoreImage
import Foundation
import ImageIO
import Vision

/// Image → transparent PNG with the background removed, using Vision's foreground
/// instance mask (the same model as "Copy Subject" in Photos). Runs on-device.
struct BackgroundRemover: Converter {
    static let inputs: Set<FileFormat> = [.png, .jpeg, .heic, .tiff, .bmp, .webp, .gif]

    func targets(for input: FileFormat) -> [FileFormat] {
        Self.inputs.contains(input) ? [.cutoutPNG] : []
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw ConversionError("Couldn't open the image.")
        }
        // Respect EXIF orientation so the cutout comes out upright.
        let orientation = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? UInt32
        let cgOrientation = orientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up

        let cutout = try Self.removeBackground(from: image, orientation: cgOrientation, cropToSubject: options.cropCutoutToSubject)
        progress(0.9)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError("Couldn't write the PNG.")
        }
        CGImageDestinationAddImage(destination, cutout, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Couldn't write the PNG.") }
        progress(1)
        return output
    }

    static func removeBackground(from image: CGImage, orientation: CGImagePropertyOrientation = .up, cropToSubject: Bool = false) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ConversionError("No subject was found to separate from the background.")
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: cropToSubject)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        guard let result = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConversionError("Couldn't create the cutout image.")
        }
        return result
    }
}
