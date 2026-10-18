import Foundation

/// A rectangular sheet of cells: the common shape between CSV, XLSX and JSON.
struct Table: Equatable, Sendable {
    var name: String = "Sheet1"
    var headers: [String]
    var rows: [[JSONValue]]

    // MARK: JSON → Table

    /// Accepts an array of objects (keys become columns, in first-seen order),
    /// an array of arrays (first row is the header), an array of scalars, or a single object.
    /// Nested arrays/objects inside cells are stored as compact JSON strings.
    init(json: JSONValue, name: String = "Sheet1") throws {
        self.name = name
        switch json {
        case .array(let items) where items.allSatisfy({ if case .object = $0 { true } else { false } }) && !items.isEmpty:
            var headers: [String] = []
            var seen = Set<String>()
            for case .object(let pairs) in items {
                for (key, _) in pairs where seen.insert(key).inserted { headers.append(key) }
            }
            self.headers = headers
            self.rows = items.map { item in headers.map { Self.cell(item[$0] ?? .null) } }
        case .array(let items) where items.allSatisfy({ if case .array = $0 { true } else { false } }) && !items.isEmpty:
            let matrix = items.map { item -> [JSONValue] in
                if case .array(let cells) = item { return cells.map(Self.cell) }
                return []
            }
            let width = matrix.map(\.count).max() ?? 0
            let padded = matrix.map { $0 + Array(repeating: .null, count: width - $0.count) }
            self.headers = padded[0].map(Self.text)
            self.rows = Array(padded.dropFirst())
        case .array(let items):
            self.headers = ["value"]
            self.rows = items.map { [Self.cell($0)] }
        case .object(let pairs):
            self.headers = pairs.map(\.0)
            self.rows = [pairs.map { Self.cell($0.1) }]
        default:
            throw ConversionError("JSON must be an array or an object to become a table.")
        }
    }

    init(name: String = "Sheet1", headers: [String], rows: [[JSONValue]]) {
        self.name = name
        self.headers = headers
        self.rows = rows
    }

    /// Builds one table per sheet when the JSON is `{"Sheet": [...], ...}`, else a single table.
    static func sheets(from json: JSONValue) throws -> [Table] {
        if case .object(let pairs) = json, !pairs.isEmpty,
           pairs.allSatisfy({ if case .array = $0.1 { true } else { false } }) {
            return try pairs.map { try Table(json: $0.1, name: $0.0) }
        }
        return [try Table(json: json)]
    }

    // MARK: Table → JSON

    /// An array of objects keyed by header. Blank headers get "column N".
    var json: JSONValue {
        let keys = uniqueKeys
        return .array(rows.map { row in
            .object(keys.enumerated().map { i, key in (key, i < row.count ? row[i] : .null) })
        })
    }

    private var uniqueKeys: [String] {
        var used = Set<String>()
        return headers.enumerated().map { i, header in
            var key = header.isEmpty ? "column \(i + 1)" : header
            var n = 2
            while used.contains(key) { key = "\(header) \(n)"; n += 1 }
            used.insert(key)
            return key
        }
    }

    // MARK: Cell helpers

    static func cell(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array, .object: .string(String(decoding: value.serialized(pretty: false), as: UTF8.self))
        default: value
        }
    }

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .null: ""
        case .bool(let b): b ? "true" : "false"
        case .number(let n): JSONValue.format(n)
        case .string(let s): s
        case .array, .object: String(decoding: value.serialized(pretty: false), as: UTF8.self)
        }
    }

    /// Turns CSV text into a typed value when that's lossless:
    /// "42" → 42, "3.5" → 3.5, "true" → true, "" → null; "007" and "1e5" stay strings.
    static func infer(_ text: String) -> JSONValue {
        if text.isEmpty { return .null }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text.wholeMatch(of: /-?(0|[1-9][0-9]{0,14})(\.[0-9]+)?/) != nil, let n = Double(text),
           JSONValue.format(n) == text || text.contains(".") && String(n) == text {
            return .number(n)
        }
        return .string(text)
    }
}
