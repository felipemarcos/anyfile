import Foundation

/// A JSON value that keeps object keys in their original order,
/// so CSV/Excel columns come out in the order the JSON lists them.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    // MARK: Parsing

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipBOM()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected content after JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ConversionError {
            ConversionError("Invalid JSON: \(message) at byte \(index).")
        }

        mutating func skipBOM() {
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func parseValue() throws -> JSONValue {
            skipWhitespace()
            guard index < bytes.count else { throw error("Unexpected end") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func expect(_ literal: String) throws {
            let chars = Array(literal.utf8)
            guard bytes.count - index >= chars.count, Array(bytes[index..<index + chars.count]) == chars else {
                throw error("Expected \(literal)")
            }
            index += chars.count
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1
            var pairs: [(String, JSONValue)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected key") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
                index += 1
                let value = try parseValue()
                if let existing = pairs.firstIndex(where: { $0.0 == key }) {
                    pairs[existing].1 = value
                } else {
                    pairs.append((key, value))
                }
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated object") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
                throw error("Expected ',' or '}'")
            }
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                items.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw error("Unterminated array") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                throw error("Expected ',' or ']'")
            }
        }

        mutating func parseString() throws -> String {
            index += 1
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw error("Bad escape") }
                    let escaped = bytes[index]
                    index += 1
                    switch escaped {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try parseHex4()
                        if (0xD800...0xDBFF).contains(scalar), bytes.count - index >= 6,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            let low = try parseHex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(scalar) ?? "\u{FFFD}")).utf8))
                    default: throw error("Bad escape")
                    }
                default:
                    out.append(byte)
                }
            }
            throw error("Unterminated string")
        }

        mutating func parseHex4() throws -> UInt32 {
            guard bytes.count - index >= 4,
                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("Bad \\u escape")
            }
            index += 4
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)) else {
                throw error("Bad number")
            }
            return .number(value)
        }
    }

    // MARK: Serializing

    func serialized(pretty: Bool = true) -> Data {
        var out = ""
        write(to: &out, indent: pretty ? 0 : nil)
        if pretty { out += "\n" }
        return Data(out.utf8)
    }

    private func write(to out: inout String, indent: Int?) {
        let newline = indent == nil ? "" : "\n"
        let pad = { (level: Int) in String(repeating: "  ", count: level) }
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += Self.format(n)
        case .string(let s): out += Self.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (i, item) in items.enumerated() {
                if let indent { out += pad(indent + 1) }
                item.write(to: &out, indent: indent.map { $0 + 1 })
                out += (i < items.count - 1 ? "," : "") + newline
            }
            if let indent { out += pad(indent) }
            out += "]"
        case .object(let pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (i, (key, value)) in pairs.enumerated() {
                if let indent { out += pad(indent + 1) }
                out += Self.quote(key) + (indent == nil ? ":" : ": ")
                value.write(to: &out, indent: indent.map { $0 + 1 })
                out += (i < pairs.count - 1 ? "," : "") + newline
            }
            if let indent { out += pad(indent) }
            out += "}"
        }
    }

    static func format(_ n: Double) -> String {
        guard n.isFinite else { return "null" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Foundation bridging (for property lists)

    init(foundation value: Any) {
        switch value {
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let d as Date: self = .string(ISO8601DateFormatter().string(from: d))
        case let d as Data: self = .string(d.base64EncodedString())
        case let a as [Any]: self = .array(a.map(JSONValue.init(foundation:)))
        case let d as [String: Any]:
            self = .object(d.keys.sorted().map { ($0, JSONValue(foundation: d[$0]!)) })
        default: self = .null
        }
    }

    /// Property lists have no null, so nulls become empty strings.
    var foundationValue: Any {
        switch self {
        case .null: ""
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let items): items.map(\.foundationValue)
        case .object(let pairs): Dictionary(pairs.map { ($0.0, $0.1.foundationValue) }, uniquingKeysWith: { _, last in last })
        }
    }
}
