import Foundation

enum OutputNamer {
    /// A URL in `directory` named after `input` with `ext`, never pointing at an existing file.
    /// `report.csv` → `report.json`, then `report (1).json`, `report (2).json`, …
    /// Pass an empty `ext` to name a folder.
    static func uniqueURL(for input: URL, ext: String, suffix: String = "", in directory: URL, fileManager: FileManager = .default) -> URL {
        let base = input.deletingPathExtension().lastPathComponent + suffix
        func candidate(_ name: String) -> URL {
            let url = directory.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var url = candidate(base)
        var n = 1
        while fileManager.fileExists(atPath: url.path) {
            url = candidate("\(base) (\(n))")
            n += 1
        }
        return url
    }
}
