import Foundation
import Testing
@testable import AnyFile

struct HTMLPageFixerTests {
    typealias Run = HTMLPageFixer.Run

    @Test func appliesStylesInOrder() {
        let html = #"<p><span style="font-family:Arial,serif;font-size:12pt">Hello</span><span style="font-family:Arial,serif;font-size:12pt"> world</span></p>"#
        let runs = [Run(text: "Hello", bold: true, italic: false, fontName: "Arial-BoldMT"),
                    Run(text: " world", bold: false, italic: true, fontName: "Arial-ItalicMT")]
        let fixed = HTMLPageFixer.applyStyles(to: html, runs: runs)
        #expect(fixed.contains(#"font-family:Arial,sans-serif;font-size:12pt;font-weight:bold">Hello"#))
        #expect(fixed.contains(#"font-style:italic"> world"#))
    }

    @Test func oneRunCanSpanSeveralSpans() {
        let html = #"<span style="font-family:Times,serif">Bold </span><span style="font-family:Times,serif">words</span>"#
        let fixed = HTMLPageFixer.applyStyles(to: html, runs: [Run(text: "Bold words", bold: true, italic: false, fontName: "Times-Bold")])
        #expect(fixed.components(separatedBy: "font-weight:bold").count == 3)
        #expect(fixed.contains("font-family:Times,serif"))
    }

    @Test func stopsStylingOnMismatch() {
        let html = #"<span style="font-family:A,serif">One</span><span style="font-family:A,serif">Two</span>"#
        let runs = [Run(text: "Uno", bold: true, italic: false, fontName: "A"), Run(text: "Two", bold: true, italic: false, fontName: "A")]
        #expect(!HTMLPageFixer.applyStyles(to: html, runs: runs).contains("font-weight"))
    }

    @Test func decodesEntitiesForMatching() {
        #expect(HTMLPageFixer.decodeEntities("a &amp; b &lt;c&gt; &#x2022; &#65; &bogus; &") == "a & b <c> • A &bogus; &")
    }

    @Test func fontFallbacks() {
        #expect(HTMLPageFixer.fixFontFamily(in: "font-family:Courier,serif", fontName: "Courier") == "font-family:Courier,monospace")
        #expect(HTMLPageFixer.fixFontFamily(in: "font-family:Georgia,serif", fontName: "Georgia") == "font-family:Georgia,serif")
        #expect(HTMLPageFixer.fixFontFamily(in: "font-family:.SFNS,serif;x:1", fontName: ".SFNS-Regular") == "font-family:-apple-system,system-ui,sans-serif;x:1")
        #expect(HTMLPageFixer.fixFontFamily(in: "font-family:Noto Sans Serif,serif", fontName: "NotoSansSerif") == "font-family:Noto Sans Serif,sans-serif")
    }
}
