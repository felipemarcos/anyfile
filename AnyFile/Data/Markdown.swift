import Foundation

/// A small Markdown → HTML renderer covering the common subset:
/// ATX headings, paragraphs, bullet/numbered lists, block quotes, fenced code,
/// horizontal rules, and inline bold, italic, code and links.
enum Markdown {
    static func html(from markdown: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }
        func closeList() {
            if let tag = listTag { html.append("</\(tag)>") }
            listTag = nil
        }
        func openList(_ tag: String) {
            if listTag != tag { closeList(); html.append("<\(tag)>"); listTag = tag }
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                    code.removeAll()
                    inCode = false
                } else {
                    flushParagraph(); closeList()
                    inCode = true
                }
                continue
            }
            if inCode { code.append(rawLine); continue }

            if line.isEmpty {
                flushParagraph(); closeList()
                continue
            }
            if let level = headingLevel(line) {
                flushParagraph(); closeList()
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inline(text))</h\(level)>")
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph(); closeList()
                html.append("<hr>")
                continue
            }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph(); closeList()
                html.append("<blockquote>\(inline(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces)))</blockquote>")
                continue
            }
            if let item = bulletItem(line) {
                flushParagraph(); openList("ul")
                html.append("<li>\(inline(item))</li>")
                continue
            }
            if let item = numberedItem(line) {
                flushParagraph(); openList("ol")
                html.append("<li>\(inline(item))</li>")
                continue
            }
            closeList()
            paragraph.append(line)
        }
        if inCode { html.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList()

        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:12pt}pre,code{font-family:Menlo,monospace;font-size:10pt}</style>
        </head><body>
        \(html.joined(separator: "\n"))
        </body></html>
        """
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(2))
        }
        return nil
    }

    private static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ text: String) -> String {
        var result = escape(text)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*([^*]+)\*\*"#, "<b>$1</b>"),
            (#"__([^_]+)__"#, "<b>$1</b>"),
            (#"\*([^*]+)\*"#, "<i>$1</i>"),
            (#"(?<![\w])_([^_]+)_(?![\w])"#, "<i>$1</i>"),
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "$1"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result
    }
}
