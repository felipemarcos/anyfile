import Foundation
import ZIPFoundation

/// Minimal Office Open XML spreadsheet (.xlsx) reading and writing.
/// Reads values (shared/inline strings, numbers, booleans, dates); formulas give their cached result.
enum XLSX {
    // MARK: Reading

    static func read(_ url: URL) throws -> [Table] {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ConversionError("This isn't a valid .xlsx file. (Legacy .xls files aren't supported.)")
        }
        func entry(_ path: String) throws -> Data? {
            guard let entry = archive[path] else { return nil }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { data.append($0) }
            return data
        }

        guard let workbookData = try entry("xl/workbook.xml") else {
            throw ConversionError("The workbook is missing from this .xlsx file.")
        }
        let sheets = WorkbookParser.parse(workbookData)
        let relationships = try entry("xl/_rels/workbook.xml.rels").map(RelationshipsParser.parse) ?? [:]
        let sharedStrings = try entry("xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        let dateStyles = try entry("xl/styles.xml").map(StylesParser.dateStyleIndexes) ?? []
        let uses1904 = WorkbookParser.uses1904(workbookData)

        var tables: [Table] = []
        for (index, sheet) in sheets.enumerated() {
            var target = relationships[sheet.relationshipID] ?? "worksheets/sheet\(index + 1).xml"
            if target.hasPrefix("/") { target.removeFirst() } else { target = "xl/" + target }
            guard let data = try entry(target) else { continue }
            let grid = SheetParser.parse(data, sharedStrings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)
            tables.append(table(from: grid, name: sheet.name))
        }
        guard !tables.isEmpty else { throw ConversionError("The workbook has no sheets.") }
        return tables
    }

    /// First non-empty row is the header.
    private static func table(from grid: [[JSONValue]], name: String) -> Table {
        let width = grid.map(\.count).max() ?? 0
        let padded = grid.map { $0 + Array(repeating: JSONValue.null, count: width - $0.count) }
        guard let headerIndex = padded.firstIndex(where: { $0.contains { $0 != .null } }) else {
            return Table(name: name, headers: [], rows: [])
        }
        var body = Array(padded[(headerIndex + 1)...])
        while let last = body.last, last.allSatisfy({ $0 == .null }) { body.removeLast() }
        return Table(name: name, headers: padded[headerIndex].map(Table.text), rows: body)
    }

    /// "AB12" → 27 (zero-based column index).
    static func columnIndex(_ reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            guard (65...90).contains(scalar.value) || (97...122).contains(scalar.value) else { break }
            value = value * 26 + Int(scalar.value & 0x1F)
            sawLetter = true
        }
        return sawLetter ? value - 1 : nil
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    // MARK: Writing

    static func write(_ tables: [Table], to url: URL) throws {
        let tables = tables.isEmpty ? [Table(headers: [], rows: [])] : tables
        let names = sheetNames(tables.map(\.name))
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create)
        } catch {
            throw ConversionError("Couldn't create the .xlsx file.")
        }

        var files: [(String, String)] = [
            ("[Content_Types].xml", contentTypes(sheetCount: tables.count)),
            ("_rels/.rels", rootRels),
            ("xl/workbook.xml", workbook(names: names)),
            ("xl/_rels/workbook.xml.rels", workbookRels(sheetCount: tables.count)),
            ("xl/styles.xml", styles),
        ]
        for (i, table) in tables.enumerated() {
            files.append(("xl/worksheets/sheet\(i + 1).xml", sheetXML(table)))
        }
        for (path, xml) in files {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    /// Excel limits sheet names to 31 characters, forbids `[]:*?/\`, and requires uniqueness.
    static func sheetNames(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.enumerated().map { i, raw in
            var name = String(raw.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            if name.isEmpty { name = "Sheet\(i + 1)" }
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(n))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    private static func sheetXML(_ table: Table) -> String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        let allRows: [[JSONValue]] = (table.headers.isEmpty ? [] : [table.headers.map(JSONValue.string)]) + table.rows
        for (r, row) in allRows.enumerated() {
            xml += #"<row r="\#(r + 1)">"#
            let isHeader = r == 0 && !table.headers.isEmpty
            for (c, value) in row.enumerated() {
                let ref = columnName(c) + String(r + 1)
                let style = isHeader ? #" s="1""# : ""
                switch value {
                case .null:
                    continue
                case .bool(let b):
                    xml += #"<c r="\#(ref)"\#(style) t="b"><v>\#(b ? 1 : 0)</v></c>"#
                case .number(let n) where n.isFinite:
                    xml += #"<c r="\#(ref)"\#(style)><v>\#(JSONValue.format(n))</v></c>"#
                default:
                    let text = escapeXML(Table.text(value))
                    xml += #"<c r="\#(ref)"\#(style) t="inlineStr"><is><t xml:space="preserve">\#(text)</t></is></c>"#
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func escapeXML(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case let c where c.value < 0x20: continue // not allowed in XML 1.0
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\#(sheets)</Types>"#
    }

    private static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#

    private static func workbook(names: [String]) -> String {
        let sheets = names.enumerated().map { i, name in
            #"<sheet name="\#(escapeXML(name))" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
        }.joined()
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\#(sheets)</sheets></workbook>"#
    }

    private static func workbookRels(sheetCount: Int) -> String {
        let sheets = (1...sheetCount).map {
            #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0).xml"/>"#
        }.joined()
        let stylesID = sheetCount + 1
        return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(sheets)<Relationship Id="rId\#(stylesID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
    }

    /// Style 0 = default, style 1 = bold (header row).
    private static let styles = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>"#
}

// MARK: - XML parsers

private final class WorkbookParser: NSObject, XMLParserDelegate {
    struct Sheet { let name: String; let relationshipID: String }
    var sheets: [Sheet] = []
    var date1904 = false

    static func parse(_ data: Data) -> [Sheet] {
        let delegate = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.sheets
    }

    static func uses1904(_ data: Data) -> Bool {
        let delegate = WorkbookParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.date1904
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "sheet":
            let rid = attributes.first { localName($0.key) == "id" }?.value ?? ""
            sheets.append(Sheet(name: attributes["name"] ?? "Sheet\(sheets.count + 1)", relationshipID: rid))
        case "workbookPr":
            date1904 = attributes["date1904"] == "1" || attributes["date1904"] == "true"
        default: break
        }
    }
}

private final class RelationshipsParser: NSObject, XMLParserDelegate {
    var targets: [String: String] = [:]

    static func parse(_ data: Data) -> [String: String] {
        let delegate = RelationshipsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.targets
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if localName(name) == "Relationship", let id = attributes["Id"], let target = attributes["Target"] {
            targets[id] = target
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false
    private var inPhonetic = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "si": inItem = true; current = ""
        case "rPh": inPhonetic = true
        case "t": inText = inItem && !inPhonetic
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "si": strings.append(current); inItem = false
        case "rPh": inPhonetic = false
        case "t": inText = false
        default: break
        }
    }
}

private final class StylesParser: NSObject, XMLParserDelegate {
    private var customDateFormats = Set<Int>()
    private var inCellXfs = false
    private var xfFormats: [Int] = []

    /// Indexes into cellXfs whose number format is a date/time.
    static func dateStyleIndexes(_ data: Data) -> Set<Int> {
        let delegate = StylesParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let builtInDates: Set<Int> = Set(14...22).union(45...47)
        return Set(delegate.xfFormats.enumerated().compactMap { index, format in
            builtInDates.contains(format) || delegate.customDateFormats.contains(format) ? index : nil
        })
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "numFmt":
            if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"], Self.isDateFormat(code) {
                customDateFormats.insert(id)
            }
        case "cellXfs": inCellXfs = true
        case "xf" where inCellXfs:
            xfFormats.append(attributes["numFmtId"].flatMap(Int.init) ?? 0)
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if localName(name) == "cellXfs" { inCellXfs = false }
    }

    /// A format is a date if it has d/m/y/h/s tokens outside quotes and brackets (ignoring colors like [Red]).
    static func isDateFormat(_ code: String) -> Bool {
        var inQuotes = false
        var inBracket = false
        var previous: Character = " "
        for c in code.lowercased() {
            defer { previous = c }
            if previous == "\\" { continue }
            if c == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if c == "[" { inBracket = true; continue }
            if c == "]" { inBracket = false; continue }
            if inBracket { continue }
            if "dmyhs".contains(c) { return true }
        }
        return false
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private let dateStyles: Set<Int>
    private let uses1904: Bool
    var rows: [Int: [Int: JSONValue]] = [:]

    private var rowIndex = 0
    private var nextColumn = 0
    private var cellColumn = 0
    private var cellType = ""
    private var cellStyle = 0
    private var value = ""
    private var inlineText = ""
    private var inValue = false
    private var inInlineText = false

    init(sharedStrings: [String], dateStyles: Set<Int>, uses1904: Bool) {
        self.sharedStrings = sharedStrings
        self.dateStyles = dateStyles
        self.uses1904 = uses1904
    }

    static func parse(_ data: Data, sharedStrings: [String], dateStyles: Set<Int>, uses1904: Bool) -> [[JSONValue]] {
        let delegate = SheetParser(sharedStrings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let maxRow = delegate.rows.keys.max() else { return [] }
        return (0...maxRow).map { r in
            guard let cells = delegate.rows[r], let maxColumn = cells.keys.max() else { return [] }
            return (0...maxColumn).map { cells[$0] ?? .null }
        }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        switch localName(name) {
        case "row":
            if let r = attributes["r"].flatMap(Int.init) { rowIndex = r - 1 } else { rowIndex = (rows.keys.max() ?? -1) + 1 }
            nextColumn = 0
        case "c":
            cellColumn = attributes["r"].flatMap(XLSX.columnIndex) ?? nextColumn
            nextColumn = cellColumn + 1
            cellType = attributes["t"] ?? "n"
            cellStyle = attributes["s"].flatMap(Int.init) ?? 0
            value = ""
            inlineText = ""
        case "v": inValue = true
        case "t": inInlineText = cellType == "inlineStr"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { value += string }
        if inInlineText { inlineText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch localName(name) {
        case "v": inValue = false
        case "t": inInlineText = false
        case "c":
            let cell = resolve()
            if cell != .null { rows[rowIndex, default: [:]][cellColumn] = cell }
        default: break
        }
    }

    private func resolve() -> JSONValue {
        switch cellType {
        case "s":
            guard let i = Int(value), sharedStrings.indices.contains(i) else { return .null }
            return .string(sharedStrings[i])
        case "inlineStr": return inlineText.isEmpty ? .null : .string(inlineText)
        case "str", "e": return value.isEmpty ? .null : .string(value)
        case "b": return .bool(value == "1")
        default:
            guard let number = Double(value) else { return value.isEmpty ? .null : .string(value) }
            if dateStyles.contains(cellStyle) { return .string(Self.isoDate(fromSerial: number, uses1904: uses1904)) }
            return .number(number)
        }
    }

    /// Excel serial day number → ISO 8601 date (or date-time when there's a time part).
    static func isoDate(fromSerial serial: Double, uses1904: Bool) -> String {
        // 1899-12-30 absorbs Excel's fictitious 1900-02-29.
        let epoch = uses1904 ? -2_082_844_800.0 : -2_209_161_600.0
        let seconds = (serial * 86_400).rounded()
        let date = Date(timeIntervalSince1970: epoch + seconds)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        if serial == serial.rounded(.down) { return day }
        if serial < 1 { return String(format: "%02d:%02d:%02d", parts.hour!, parts.minute!, parts.second!) }
        return day + String(format: "T%02d:%02d:%02d", parts.hour!, parts.minute!, parts.second!)
    }
}

private func localName(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}
