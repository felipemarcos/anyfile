import Foundation
import PDFKit

enum MuPDFLocator {
    /// The mutool bundled in the app, else a Homebrew/MacPorts install (`brew install mupdf-tools`).
    static func find(bundle: Bundle = .main) -> URL? {
        if let bundled = bundle.url(forResource: "mutool", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/mutool", "/usr/local/bin/mutool", "/opt/local/bin/mutool"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Conversion with MuPDF's mutool: PDF/Illustrator → SVG or HTML, and SVG → PNG/PDF.
struct MuPDFConverter: Converter {
    let executable: URL

    func targets(for input: FileFormat) -> [FileFormat] {
        switch input {
        case .pdf, .ai: [.svg, .html]
        case .svg: [.png, .pdf]
        default: []
        }
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        switch (source, target) {
        case (.svg, .png):
            try await run(["draw", "-q", "-r", "144", "-o", output.path, input.path])
        case (.svg, .pdf):
            try await run(["convert", "-o", output.path, input.path])
        case (.pdf, .svg), (.ai, .svg):
            return try await writeSVG(input, from: source, output: output, progress: progress)
        case (.pdf, .html), (.ai, .html):
            try await writeHTML(input, from: source, output: output, progress: progress)
        default:
            throw ConversionError("MuPDF can't convert \(source.displayName) to \(target.displayName).")
        }
        progress(1)
        return output
    }

    /// One SVG per page; several pages go into a folder named after the input.
    /// Text becomes outlines so the SVG looks the same without the document's fonts.
    private func writeSVG(_ input: URL, from source: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws -> URL {
        guard let pageCount = PDFDocument(url: input)?.pageCount, pageCount > 0 else {
            throw ConversionError(source == .ai
                ? "This Illustrator file was saved without PDF compatibility. Re-save it in Illustrator with \"Create PDF Compatible File\" on."
                : "Couldn't open the PDF.")
        }
        let svgArgs = ["draw", "-q", "-F", "svg", "-O", "text=path"]
        if pageCount == 1 {
            try await run(svgArgs + ["-o", output.path, input.path, "1"])
            progress(1)
            return output
        }

        let folder = OutputNamer.uniqueURL(for: input, ext: "", in: output.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let base = input.deletingPathExtension().lastPathComponent
        let digits = String(pageCount).count
        do {
            for page in 1...pageCount {
                try Task.checkCancellation()
                let number = String(repeating: "0", count: digits - String(page).count) + String(page)
                let pageURL = folder.appendingPathComponent("\(base)-\(number).svg")
                try await run(svgArgs + ["-o", pageURL.path, input.path, String(page)])
                progress(Double(page) / Double(pageCount))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return folder
    }

    /// One HTML file with every page laid out as in the PDF (positioned text, embedded images),
    /// with bold and italic restored from MuPDF's structured-text output.
    private func writeHTML(_ input: URL, from source: FileFormat, output: URL, progress: @escaping ProgressHandler) async throws {
        guard PDFDocument(url: input) != nil else {
            throw ConversionError(source == .ai
                ? "This Illustrator file was saved without PDF compatibility. Re-save it in Illustrator with \"Create PDF Compatible File\" on."
                : "Couldn't open the PDF.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let html = work.appendingPathComponent("page.html")
        let stext = work.appendingPathComponent("page.json")
        try await run(["draw", "-q", "-F", "html", "-O", "preserve-images", "-o", html.path, input.path])
        progress(0.5)
        try await run(["draw", "-q", "-F", "stext.json", "-o", stext.path, input.path])
        progress(0.8)

        let fixed = HTMLPageFixer.fix(
            html: try String(contentsOf: html, encoding: .utf8),
            stextJSON: try Data(contentsOf: stext),
            title: input.deletingPathExtension().lastPathComponent)
        try Data(fixed.utf8).write(to: output, options: .atomic)
    }

    private func run(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: ConversionError("Couldn't start mutool: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        try Task.checkCancellation()
        guard status == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "exit code \(status)"
            throw ConversionError("MuPDF failed: \(message)")
        }
    }
}
