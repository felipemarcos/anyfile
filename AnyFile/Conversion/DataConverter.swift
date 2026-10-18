import Foundation

/// Structured data: JSON, property lists, CSV and Excel.
struct DataConverter: Converter {
    func targets(for input: FileFormat) -> [FileFormat] {
        switch input {
        case .json: [.csv, .xlsx, .plist]
        case .plist: [.json, .csv, .xlsx]
        case .csv: [.json, .xlsx]
        case .xlsx: [.json, .csv]
        default: []
        }
    }

    func convert(_ input: URL, from source: FileFormat, to target: FileFormat, output: URL, options: ConversionOptions, progress: @escaping ProgressHandler) async throws -> URL {
        let data: Data
        switch (source, target) {
        case (.csv, .json):
            data = CSV.table(from: try Self.readText(input)).json.serialized()
        case (.csv, .xlsx):
            try XLSX.write([CSV.table(from: try Self.readText(input))], to: output)
            progress(1)
            return output

        case (.xlsx, .json):
            let tables = try XLSX.read(input)
            if options.allSheets && tables.count > 1 {
                data = JSONValue.object(tables.map { ($0.name, $0.json) }).serialized()
            } else {
                data = tables[0].json.serialized()
            }
        case (.xlsx, .csv):
            data = Data(CSV.text(from: try XLSX.read(input)[0]).utf8)

        case (.json, _), (.plist, _):
            let value = source == .json
                ? try JSONValue.parse(try Data(contentsOf: input))
                : try Self.readPlist(input)
            switch target {
            case .json:
                data = value.serialized()
            case .plist:
                data = try PropertyListSerialization.data(fromPropertyList: value.foundationValue, format: .xml, options: 0)
            case .csv:
                data = Data(CSV.text(from: try Table.sheets(from: value)[0]).utf8)
            case .xlsx:
                try XLSX.write(try Table.sheets(from: value), to: output)
                progress(1)
                return output
            default:
                throw ConversionError("Unsupported target \(target.displayName).")
            }

        default:
            throw ConversionError("Can't convert \(source.displayName) to \(target.displayName).")
        }
        try data.write(to: output, options: .atomic)
        progress(1)
        return output
    }

    /// UTF-8, falling back to Windows-1252 (common for CSVs exported from Excel).
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        throw ConversionError("The file's text encoding isn't supported.")
    }

    static func readPlist(_ url: URL) throws -> JSONValue {
        let object = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), format: nil)
        return JSONValue(foundation: object)
    }
}
