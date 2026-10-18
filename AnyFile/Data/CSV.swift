import Foundation

/// RFC 4180 CSV reading and writing.
enum CSV {
    /// Parses CSV text into rows of fields. Handles quoted fields, doubled quotes
    /// and line breaks inside quotes. The delimiter is detected when not given.
    static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delimiter = delimiter ?? detectDelimiter(text)

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var iterator = text.makeIterator()
        var pending: Character?

        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where !fieldStarted && field.isEmpty:
                inQuotes = true
                fieldStarted = true
            case delimiter:
                endField()
            case "\n", "\r\n", "\r":
                endRow()
            default:
                field.append(c)
                fieldStarted = true
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldStarted { endRow() }
        return rows
    }

    /// Picks the most frequent of `,` `;` tab `|` on the first line (outside quotes).
    static func detectDelimiter(_ text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t", "|"]
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            if !inQuotes, c == "\n" || c == "\r\n" || c == "\r" { break }
            if !inQuotes, candidates.contains(c) { counts[c, default: 0] += 1 }
        }
        return candidates.max { counts[$0, default: 0] < counts[$1, default: 0] }.flatMap { counts[$0] != nil ? $0 : nil } ?? ","
    }

    static func write(_ rows: [[String]], delimiter: Character = ",") -> String {
        rows.map { row in row.map { escape($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }
            .joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ field: String, delimiter: Character) -> String {
        guard field.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
                || field.hasPrefix(" ") || field.hasSuffix(" ") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Table bridging

    static func table(from text: String) -> Table {
        let rows = parse(text)
        guard let header = rows.first else { return Table(headers: [], rows: []) }
        let width = rows.map(\.count).max() ?? header.count
        let headers = header + Array(repeating: "", count: width - header.count)
        let text = rows.dropFirst().map { $0 + Array(repeating: "", count: width - $0.count) }
        // A column is typed only when every non-empty cell converts losslessly, so a
        // zip-code column with "01234" stays all strings instead of mixing types.
        var columns = Array(repeating: [JSONValue](), count: width)
        for column in 0..<width {
            let inferred = text.map { Table.infer($0[column]) }
            let typed = inferred.allSatisfy { if case .string = $0 { false } else { true } }
            let consistent = Set(inferred.compactMap { value -> String? in
                switch value {
                case .number: "number"
                case .bool: "bool"
                default: nil
                }
            }).count <= 1
            columns[column] = typed && consistent
                ? inferred
                : text.map { $0[column].isEmpty ? .null : .string($0[column]) }
        }
        let body = text.indices.map { r in (0..<width).map { columns[$0][r] } }
        return Table(headers: headers, rows: body)
    }

    static func text(from table: Table) -> String {
        write([table.headers] + table.rows.map { $0.map(Table.text) })
    }
}
