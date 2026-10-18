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
        ffmpegPath = defaults.string(forKey: Keys.ffmpegPath)
        optimizeSVG = defaults.object(forKey: Keys.optimizeSVG) as? Bool ?? true
    }

    var options: ConversionOptions {
        ConversionOptions(imageQuality: imageQuality, allSheets: allSheets, optimizeSVG: optimizeSVG)
    }

    private enum Keys {
        static let outputFolder = "outputFolder"
        static let imageQuality = "imageQuality"
        static let allSheets = "allSheets"
        static let ffmpegPath = "ffmpegPath"
        static let optimizeSVG = "optimizeSVG"
    }
}
