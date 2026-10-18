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
        renderDPI = defaults.object(forKey: Keys.renderDPI) as? Double ?? 144
        ffmpegPath = defaults.string(forKey: Keys.ffmpegPath)
        optimizeSVG = defaults.object(forKey: Keys.optimizeSVG) as? Bool ?? true
    }

    var options: ConversionOptions {
        ConversionOptions(imageQuality: imageQuality, renderDPI: renderDPI, allSheets: allSheets, optimizeSVG: optimizeSVG)
    }

    private enum Keys {
        static let outputFolder = "outputFolder"
        static let imageQuality = "imageQuality"
        static let allSheets = "allSheets"
        static let renderDPI = "renderDPI"
        static let ffmpegPath = "ffmpegPath"
        static let optimizeSVG = "optimizeSVG"
    }
}
