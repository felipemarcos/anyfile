import Foundation
import Testing
@testable import AnyFile

/// Converts a real file of yours with the app's own pipeline. Runs only when a path is given:
///   TEST_RUNNER_ANYFILE_SAMPLE=/path/to/file.ai TEST_RUNNER_ANYFILE_OUT=/tmp/out \
///   xcodebuild test -only-testing:AnyFileTests/LocalFileTests …
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ANYFILE_SAMPLE"] != nil, "set TEST_RUNNER_ANYFILE_SAMPLE"))
struct LocalFileTests {
    @Test func convertSampleToSVG() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: env["ANYFILE_SAMPLE"]!)
        let outDir = URL(fileURLWithPath: env["ANYFILE_OUT"] ?? FileManager.default.temporaryDirectory.path)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let source = try #require(FileFormat.detect(input))
        let registry = ConverterRegistry.standard()
        let converter = try #require(registry.converter(from: source, to: .svg))

        for optimize in [false, true] {
            let output = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent + (optimize ? "-svgo" : "-raw") + ".svg")
            try? FileManager.default.removeItem(at: output)
            let start = Date()
            let written = try await converter.convert(input, from: source, to: .svg, output: output,
                                                      options: .init(optimizeSVG: optimize), progress: { _ in })
            let size = try FileManager.default.attributesOfItem(atPath: written.path)[.size] as? Int ?? 0
            print("ANYFILE \(optimize ? "svgo" : "raw ") \(size) bytes in \(String(format: "%.2f", Date().timeIntervalSince(start)))s -> \(written.path)")
            #expect(size > 0)

            // Round trip: render the SVG back to PNG with the app's SVG converter.
            if optimize {
                let png = output.deletingPathExtension().appendingPathExtension("png")
                try? FileManager.default.removeItem(at: png)
                _ = try await SVGConverter().convert(written, from: .svg, to: .png, output: png, options: .init(), progress: { _ in })
                print("ANYFILE png  -> \(png.path)")
            }
        }
    }
}
