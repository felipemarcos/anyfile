import Foundation
import Testing
@testable import AnyFile

struct SVGOptimizerTests {
    @Test func loadsSVGOAndShrinksMarkup() async throws {
        #expect(try await SVGOptimizer.shared.version == "4.1.0")
        let svg = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!-- comment -->
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="100" height="100" viewBox="0 0 100 100">
          <g><g><rect x="10.000000" y="10.000000" width="80.000000" height="80.000000" fill="#ff0000"/></g></g>
        </svg>
        """
        let out = try await SVGOptimizer.shared.optimize(svg)
        #expect(out.count < svg.count / 2)
        #expect(out.contains(#"viewBox="0 0 100 100""#))
        #expect(!out.contains("<!--"))
        #expect(out.contains("#f00") || out.contains("red"))
    }

    @Test func rejectsInvalidSVG() async {
        await #expect(throws: ConversionError.self) {
            _ = try await SVGOptimizer.shared.optimize("<svg><g></svg")
        }
    }
}
