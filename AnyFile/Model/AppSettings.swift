import Foundation
import Observation

/// Preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// nil = save next to the original file.
    var outputFolder: URL? {
        didSet { defaults.set(outputFolder?.path, forKey: Keys.outputFolder) }
    }

    var imageQuality: Double {
        didSet { defaults.set(imageQuality, forKey: Keys.imageQuality) }
    }

    /// See `ConversionOptions.renderDPI`.
    var renderDPI: Double {
        didSet { defaults.set(renderDPI, forKey: Keys.renderDPI) }
    }

    /// Presets offered in Settings: (dpi, label).
    static let renderDPIPresets: [(Double, String)] = [
        (72, "1× (72 dpi)"), (144, "2× (144 dpi)"), (216, "3× (216 dpi)"), (288, "4× (288 dpi)"),
        (300, "Print (300 dpi)"), (600, "High (600 dpi)"),
    ]

    /// OCR language code, or nil for automatic detection.
    var ocrLanguage: String? {
        didSet { defaults.set(ocrLanguage, forKey: Keys.ocrLanguage) }
    }

    var ocrScannedPages: Bool {
        didSet { defaults.set(ocrScannedPages, forKey: Keys.ocrScannedPages) }
    }

    /// Vectorize: palette size (0 = automatic) and outline smoothing tolerance in pixels.
    var vectorizeColors: Int {
        didSet { defaults.set(vectorizeColors, forKey: Keys.vectorizeColors) }
    }

    var vectorizeTolerance: Double {
        didSet { defaults.set(vectorizeTolerance, forKey: Keys.vectorizeTolerance) }
    }

    var cropCutoutToSubject: Bool {
        didSet { defaults.set(cropCutoutToSubject, forKey: Keys.cropCutoutToSubject) }
    }

    /// Speech-to-text locale, or nil for the system language.
    var transcriptionLocale: String? {
        didSet { defaults.set(transcriptionLocale, forKey: Keys.transcriptionLocale) }
    }

    var allSheets: Bool {
        didSet { defaults.set(allSheets, forKey: Keys.allSheets) }
    }

    var optimizeSVG: Bool {
        didSet { defaults.set(optimizeSVG, forKey: Keys.optimizeSVG) }
    }

    /// nil = automatic (bundled, then Homebrew/MacPorts).
    var ffmpegPath: String? {
        didSet { defaults.set(ffmpegPath, forKey: Keys.ffmpegPath) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        outputFolder = defaults.string(forKey: Keys.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
        imageQuality = defaults.object(forKey: Keys.imageQuality) as? Double ?? 0.85
        allSheets = defaults.bool(forKey: Keys.allSheets)
        ocrLanguage = defaults.string(forKey: Keys.ocrLanguage)
        ocrScannedPages = defaults.object(forKey: Keys.ocrScannedPages) as? Bool ?? true
        renderDPI = defaults.object(forKey: Keys.renderDPI) as? Double ?? 144
        ffmpegPath = defaults.string(forKey: Keys.ffmpegPath)
        optimizeSVG = defaults.object(forKey: Keys.optimizeSVG) as? Bool ?? true
        vectorizeColors = defaults.integer(forKey: Keys.vectorizeColors)
        vectorizeTolerance = defaults.object(forKey: Keys.vectorizeTolerance) as? Double ?? 1.0
        cropCutoutToSubject = defaults.bool(forKey: Keys.cropCutoutToSubject)
        transcriptionLocale = defaults.string(forKey: Keys.transcriptionLocale)
    }

    var options: ConversionOptions {
        ConversionOptions(imageQuality: imageQuality, renderDPI: renderDPI, allSheets: allSheets, optimizeSVG: optimizeSVG,
                          ocrLanguage: ocrLanguage, ocrScannedPages: ocrScannedPages,
                          vectorize: .init(colors: vectorizeColors > 0 ? vectorizeColors : nil, tolerance: vectorizeTolerance),
                          cropCutoutToSubject: cropCutoutToSubject, transcriptionLocale: transcriptionLocale)
    }

    private enum Keys {
        static let outputFolder = "outputFolder"
        static let imageQuality = "imageQuality"
        static let allSheets = "allSheets"
        static let ocrLanguage = "ocrLanguage"
        static let ocrScannedPages = "ocrScannedPages"
        static let renderDPI = "renderDPI"
        static let ffmpegPath = "ffmpegPath"
        static let optimizeSVG = "optimizeSVG"
        static let vectorizeColors = "vectorizeColors"
        static let vectorizeTolerance = "vectorizeTolerance"
        static let cropCutoutToSubject = "cropCutoutToSubject"
        static let transcriptionLocale = "transcriptionLocale"
    }
}
