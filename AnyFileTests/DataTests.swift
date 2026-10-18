import Foundation
import Testing
@testable import AnyFile

struct CSVTests {
    @Test func parsesQuotesEscapesAndNewlines() {
        let rows = CSV.parse("name,note\r\n\"Doe, Jane\",\"said \"\"hi\"\"\nthen left\"\nBob,\n")
        #expect(rows == [["name", "note"], ["Doe, Jane", "said \"hi\"\nthen left"], ["Bob", ""]])
    }

    @Test func detectsSemicolonAndTab() {
        #expect(CSV.detectDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSV.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSV.detectDelimiter("\"x,y\";z\n") == ";")
    }

    @Test func writeRoundTrips() {
        let rows = [["a", "b,c"], ["\"q\"", "line\nbreak"], [" pad", ""]]
        #expect(CSV.parse(CSV.write(rows)) == rows)
    }

    @Test func infersOnlyLosslessTypes() {
        #expect(Table.infer("42") == .number(42))
        #expect(Table.infer("-3.5") == .number(-3.5))
        #expect(Table.infer("007") == .string("007"))
        #expect(Table.infer("3.50") == .string("3.50"))
        #expect(Table.infer("1e5") == .string("1e5"))
        #expect(Table.infer("true") == .bool(true))
        #expect(Table.infer("") == .null)
    }

    @Test func csvToJSONAndBack() throws {
        let csv = "id,name,zip\n1,Ana,01234\n2,\"Lee, B\",90210\n"
        let json = CSV.table(from: csv).json
        #expect(json == .array([
            .object([("id", .number(1)), ("name", .string("Ana")), ("zip", .string("01234"))]),
            .object([("id", .number(2)), ("name", .string("Lee, B")), ("zip", .string("90210"))]),
        ]))
        let back = CSV.text(from: try Table(json: json))
        #expect(CSV.parse(back) == CSV.parse(csv))
    }
}

struct JSONValueTests {
    @Test func preservesKeyOrder() throws {
        let value = try JSONValue.parse(Data(#"{"z":1,"a":[true,null,"xé\n"],"m":{"k":-2.5}}"#.utf8))
        guard case .object(let pairs) = value else { Issue.record("not an object"); return }
        #expect(pairs.map(\.0) == ["z", "a", "m"])
        #expect(value["a"] == .array([.bool(true), .null, .string("xé\n")]))
        #expect(try JSONValue.parse(value.serialized()) == value)
    }

    @Test func rejectsInvalidJSON() {
        #expect(throws: ConversionError.self) { try JSONValue.parse(Data("{\"a\":}".utf8)) }
        #expect(throws: ConversionError.self) { try JSONValue.parse(Data("[1] x".utf8)) }
    }

    @Test func tableUnionsKeysInFirstSeenOrder() throws {
        let json = try JSONValue.parse(Data(#"[{"b":1,"a":2},{"c":{"n":1},"a":3}]"#.utf8))
        let table = try Table(json: json)
        #expect(table.headers == ["b", "a", "c"])
        #expect(table.rows == [[.number(1), .number(2), .null], [.null, .number(3), .string(#"{"n":1}"#)]])
    }
}

struct XLSXTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AnyFileTests-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @Test func writeThenReadRoundTrips() throws {
        let people = Table(name: "People", headers: ["name", "age", "member", "note"], rows: [
            [.string("Ana"), .number(31), .bool(true), .string("<&> \"quoted\"")],
            [.string("Bo"), .number(2.5), .bool(false), .null],
        ])
        let other = Table(name: "Bad/Name:With*Chars", headers: ["x"], rows: [[.number(1)]])
        let url = dir.appendingPathComponent("test.xlsx")
        try XLSX.write([people, other], to: url)

        let tables = try XLSX.read(url)
        #expect(tables.count == 2)
        #expect(tables[0] == people)
        #expect(tables[1].name == "BadNameWithChars")
        #expect(tables[1].rows == [[.number(1)]])
    }

    @Test func columnReferences() {
        #expect(XLSX.columnIndex("A1") == 0)
        #expect(XLSX.columnIndex("Z9") == 25)
        #expect(XLSX.columnIndex("AA10") == 26)
        #expect(XLSX.columnName(27) == "AB")
        #expect(XLSX.columnName(701) == "ZZ")
    }

    @Test func dataConverterJSONToXLSXToJSON() async throws {
        let json = dir.appendingPathComponent("in.json")
        try Data(#"[{"city":"Lisbon","pop":545000},{"city":"Porto","pop":232000}]"#.utf8).write(to: json)
        let xlsx = dir.appendingPathComponent("out.xlsx")
        let back = dir.appendingPathComponent("back.json")
        let converter = DataConverter()
        _ = try await converter.convert(json, from: .json, to: .xlsx, output: xlsx, options: .init(), progress: { _ in })
        _ = try await converter.convert(xlsx, from: .xlsx, to: .json, output: back, options: .init(), progress: { _ in })
        #expect(try JSONValue.parse(Data(contentsOf: back)) == JSONValue.parse(Data(contentsOf: json)))
    }

    @Test func plistRoundTrip() async throws {
        let json = dir.appendingPathComponent("p.json")
        try Data(#"{"name":"x","count":3,"on":true,"list":[1,2]}"#.utf8).write(to: json)
        let plist = dir.appendingPathComponent("p.plist")
        let back = dir.appendingPathComponent("p2.json")
        let converter = DataConverter()
        _ = try await converter.convert(json, from: .json, to: .plist, output: plist, options: .init(), progress: { _ in })
        _ = try await converter.convert(plist, from: .plist, to: .json, output: back, options: .init(), progress: { _ in })
        let result = try JSONValue.parse(Data(contentsOf: back))
        #expect(result["count"] == .number(3))
        #expect(result["on"] == .bool(true))
        #expect(result["list"] == .array([.number(1), .number(2)]))
    }
}
