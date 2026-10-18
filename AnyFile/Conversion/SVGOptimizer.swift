import Foundation
import JavaScriptCore

/// Optimizes SVG with SVGO (the engine behind SVGOMG), run locally in JavaScriptCore.
/// Uses SVGOMG's defaults: the default preset, multipass, 3-digit precision.
/// The vendored file is SVGO's unmodified browser build (Resources/svgo.browser.js, MIT).
actor SVGOptimizer {
    static let shared = SVGOptimizer()

    private var context: JSContext?

    var version: String {
        get throws { try loadedContext().evaluateScript("svgo.VERSION")?.toString() ?? "" }
    }

    func optimize(_ svg: String) throws -> String {
        let context = try loadedContext()
        context.exception = nil
        context.setObject(svg, forKeyedSubscript: "input" as NSString)
        let result = context.evaluateScript("svgo.optimize(input, { multipass: true, floatPrecision: 3 }).data")
        context.setObject(nil, forKeyedSubscript: "input" as NSString)
        if let exception = context.exception {
            throw ConversionError("SVGO couldn't optimize the SVG: \(exception.toString() ?? "unknown error")")
        }
        guard let output = result?.toString(), !output.isEmpty, output != "undefined" else {
            throw ConversionError("SVGO returned no output.")
        }
        return output
    }

    /// Optimizes an SVG file in place. Returns the (before, after) sizes in bytes.
    @discardableResult
    func optimizeFile(at url: URL) throws -> (Int, Int) {
        let original = try String(contentsOf: url, encoding: .utf8)
        let optimized = try optimize(original)
        try Data(optimized.utf8).write(to: url, options: .atomic)
        return (original.utf8.count, optimized.utf8.count)
    }

    private func loadedContext() throws -> JSContext {
        if let context { return context }
        guard let url = Bundle(for: BundleToken.self).url(forResource: "svgo.browser", withExtension: "js")
                ?? Bundle.main.url(forResource: "svgo.browser", withExtension: "js"),
              var source = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConversionError("SVGO is missing from the app.")
        }
        // The browser build is an ES module ending in `export{…}`; JSContext runs classic scripts,
        // so expose the exports as a global instead.
        guard let range = source.range(of: #"export\s*\{[^}]*\}\s*;?\s*$"#, options: .regularExpression) else {
            throw ConversionError("Unexpected SVGO build format.")
        }
        source.replaceSubrange(range, with: "globalThis.svgo = { VERSION, optimize };")

        guard let context = JSContext() else { throw ConversionError("Couldn't start JavaScriptCore.") }
        context.evaluateScript(source, withSourceURL: url)
        if let exception = context.exception {
            throw ConversionError("Couldn't load SVGO: \(exception.toString() ?? "unknown error")")
        }
        self.context = context
        return context
    }
}

private final class BundleToken {}
