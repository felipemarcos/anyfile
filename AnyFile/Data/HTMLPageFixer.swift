import Foundation

/// Improves MuPDF's layout-preserving HTML: restores bold/italic (which its HTML writer drops)
/// from the structured-text JSON of the same document, picks sensible font fallbacks, and adds
/// a charset and title.
enum HTMLPageFixer {
    struct Run: Equatable {
        let text: String
        let bold: Bool
        let italic: Bool
        let fontName: String
    }

    static func fix(html: String, stextJSON: Data, title: String) -> String {
        let runs = (try? runs(fromStext: stextJSON)) ?? []
        var result = applyStyles(to: html, runs: runs)
        result = result.replacingOccurrences(
            of: "<head>",
            with: "<head>\n<meta charset=\"utf-8\">\n<title>\(Markdown.escape(title))</title>",
            options: [], range: result.range(of: "<head>"))
        return result
    }

    /// Text runs in document order. MuPDF's stext JSON calls them "lines"; each has one font.
    static func runs(fromStext data: Data) throws -> [Run] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pages = root["pages"] as? [[String: Any]] else { return [] }
        var runs: [Run] = []
        for page in pages {
            for block in page["blocks"] as? [[String: Any]] ?? [] where block["type"] as? String == "text" {
                for line in block["lines"] as? [[String: Any]] ?? [] {
                    let font = line["font"] as? [String: Any] ?? [:]
                    runs.append(Run(
                        text: line["text"] as? String ?? "",
                        bold: (font["weight"] as? String) == "bold",
                        italic: (font["style"] as? String) == "italic",
                        fontName: font["name"] as? String ?? ""))
                }
            }
        }
        return runs
    }

    private static let spanPattern = try! NSRegularExpression(pattern: #"<span style="([^"]*)">([^<]*)</span>"#)

    /// Walks the HTML spans and the runs together. A run can cover several spans (MuPDF may split
    /// one run's text), so spans are matched against the remaining text of the current run. On the
    /// first mismatch, styling stops and the rest of the HTML keeps MuPDF's output unchanged.
    static func applyStyles(to html: String, runs: [Run]) -> String {
        let ns = html as NSString
        var output = ""
        var cursor = 0
        var runIndex = 0
        var remaining = runs.first.map { normalize($0.text) } ?? ""
        var matching = !runs.isEmpty

        for match in spanPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            cursor = match.range.location + match.range.length
            var style = ns.substring(with: match.range(at: 1))
            let inner = ns.substring(with: match.range(at: 2))
            let text = normalize(decodeEntities(inner))

            var run: Run?
            if matching {
                while remaining.isEmpty, runIndex + 1 < runs.count {
                    runIndex += 1
                    remaining = normalize(runs[runIndex].text)
                }
                if !text.isEmpty, remaining.hasPrefix(text) {
                    run = runs[runIndex]
                    remaining = String(remaining.dropFirst(text.count))
                } else if !text.isEmpty {
                    matching = false
                }
            }

            style = fixFontFamily(in: style, fontName: run?.fontName)
            if run?.bold == true { style += ";font-weight:bold" }
            if run?.italic == true { style += ";font-style:italic" }
            output += "<span style=\"\(style)\">\(inner)</span>"
        }
        output += ns.substring(from: cursor)
        return output
    }

    /// MuPDF labels every font's fallback as "serif"; choose one from the font's name instead,
    /// and map Apple's private ".SFNS" system font names to the system font stack.
    static func fixFontFamily(in style: String, fontName: String?) -> String {
        guard let range = style.range(of: #"font-family:[^;]*"#, options: .regularExpression) else { return style }
        let families = style[range].dropFirst("font-family:".count).split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard var primary = families.first else { return style }
        let name = (fontName ?? primary).lowercased()
        let generic: String
        if name.contains("mono") || name.contains("courier") || name.contains("menlo") || name.contains("consol") {
            generic = "monospace"
        } else if !name.contains("sans") && ["times", "serif", "georgia", "garamond", "minion", "palatino", "cambria", "baskerville", "book"].contains(where: name.contains) {
            generic = "serif"
        } else {
            generic = "sans-serif"
        }
        if primary.hasPrefix(".SF") { primary = "-apple-system,system-ui" }
        return style.replacingCharacters(in: range, with: "font-family:\(primary),\(generic)")
    }

    static func normalize(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                result.append("&"); rest = rest.dropFirst(); continue
            }
            let entity = rest[rest.index(after: amp)..<semi]
            var scalar: Unicode.Scalar?
            switch entity {
            case "amp": scalar = "&"
            case "lt": scalar = "<"
            case "gt": scalar = ">"
            case "quot": scalar = "\""
            case "apos": scalar = "'"
            case "nbsp": scalar = "\u{00A0}"
            default:
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init)
                }
            }
            if let scalar {
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: semi)...]
            } else {
                result.append("&"); rest = rest.dropFirst()
            }
        }
        return result + rest
    }
}
