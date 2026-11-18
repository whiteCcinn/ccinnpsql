import Foundation
import PostgresKit
import Testing
@testable import CcinnPsqlKit

@Suite("Result export formats")
struct ResultExportFormatTests {
    /// bigint, text, numeric(12,2), boolean, double precision
    let columns = [ColumnDescription(name: "id", typeOID: 20), ColumnDescription(name: "city", typeOID: 25),
                   ColumnDescription(name: "total", typeOID: 1700, typeModifier: Int32((12 << 16) | 2) + 4),
                   ColumnDescription(name: "paid", typeOID: 16), ColumnDescription(name: "ratio", typeOID: 701)]
    let rows: [[String?]] = [["1", "Kuala Lumpur", "12.50", "t", "0.5"], ["2", "O'Neil", nil, "f", "NaN"], ["3", nil, "-0.5", nil, "Infinity"]]

    private func temporaryURL(_ fileExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-format-\(UUID().uuidString).\(fileExtension)")
    }

    @Test func formatsAndWhatTheyAreFor() {
        #expect(ExportFormat.allCases == [.csv, .tsv, .excel, .json, .markdown, .insert, .multiRowInsert])
        #expect(ExportFormat.allCases.filter { !$0.isCopyable } == [.excel], "a workbook is a file only")
        #expect(ExportFormat.excel.fileExtension == "xlsx")
        #expect(ExportFormat.multiRowInsert.fileExtension == "sql")
    }

    @Test func multiRowInsertListsOneRowPerLine() {
        #expect(ResultExport.render(.multiRowInsert, columns: columns, rows: rows, table: "shop.orders") == """
        INSERT INTO shop.orders (id, city, total, paid, ratio) VALUES
          (1, 'Kuala Lumpur', 12.50, true, 0.5),
          (2, 'O''Neil', NULL, false, 'NaN'),
          (3, NULL, -0.5, NULL, 'Infinity');

        """)
        #expect(ResultExport.render(.multiRowInsert, columns: columns, rows: [], table: "t").isEmpty)
    }

    // Each statement stays small: a new one every N rows or past the byte budget.
    @Test func multiRowInsertStartsANewStatementByRowsAndBySize() {
        let many = (1...5).map { ["\($0)", "c\($0)", "\($0).0", "t", "1"] as [String?] }
        let byRows = ResultExport.multiRowInsert(table: "t", columns: columns, rows: many, rowsPerStatement: 2)
        #expect(byRows.components(separatedBy: "INSERT INTO").count - 1 == 3)
        #expect(byRows.contains("(2, 'c2', 2.0, true, 1);\nINSERT INTO t (id, city, total, paid, ratio) VALUES\n  (3, 'c3', 3.0, true, 1),"))
        let big = String(repeating: "x", count: 600)
        let bySize = ResultExport.multiRowInsert(table: "t", columns: columns, rows: [["1", big, nil, nil, nil], ["2", big, nil, nil, nil], ["3", "s", nil, nil, nil]],
                                                 maxStatementBytes: 1_000)
        #expect(bySize.components(separatedBy: "INSERT INTO").count - 1 == 2)
    }

    // A bare NaN or Infinity is a column name to PostgreSQL; quoted, numeric and float columns accept them.
    @Test func nonFiniteNumbersAreQuotedInEveryInsert() {
        #expect(ResultExport.insertStatements(table: "t", columns: [ColumnDescription(name: "x", typeOID: 701)], rows: [["NaN"], ["-Infinity"], ["1.5"]]) == """
        INSERT INTO t (x) VALUES ('NaN');
        INSERT INTO t (x) VALUES ('-Infinity');
        INSERT INTO t (x) VALUES (1.5);

        """)
    }

    @Test func excelCellKindsFollowPostgresTypes() {
        let typed = [ColumnDescription(name: "a", typeOID: 20), ColumnDescription(name: "b", typeOID: 23),
                     ColumnDescription(name: "c", typeOID: 1700, typeModifier: Int32((10 << 16) | 3) + 4), ColumnDescription(name: "d", typeOID: 1700),
                     ColumnDescription(name: "e", typeOID: 701), ColumnDescription(name: "f", typeOID: 16), ColumnDescription(name: "g", typeOID: 1184)]
        #expect(ResultExport.cellKinds(typed) == [.integer, .integer, .decimal(scale: 3), .decimal(scale: nil), .approximateNumber, .text, .text])
    }

    @Test func excelTypesCellsAndSpellsBooleans() throws {
        let url = temporaryURL("xlsx")
        defer { try? FileManager.default.removeItem(at: url) }
        let summary = try ResultExport.write(.excel, to: url, columns: columns, rows: rows, table: "t", sheetName: "orders")
        #expect(summary == XLSXWriter.Summary(rows: 3, truncatedCells: 0))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "xl/worksheets/sheet1.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let sheet = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(sheet.contains("<c r=\"A2\" s=\"2\"><v>1</v></c>"))
        #expect(sheet.contains("<c r=\"C2\" s=\"3\"><v>12.50</v></c>"))
        #expect(sheet.contains("<c r=\"D2\" t=\"inlineStr\"><is><t xml:space=\"preserve\">true</t></is></c>"))
        #expect(sheet.contains("<c r=\"D3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">false</t></is></c>"))
        #expect(sheet.contains("<c r=\"E3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">NaN</t></is></c>"))
        #expect(sheet.contains("<c r=\"E2\"><v>0.5</v></c>"))
    }

    @Test func textFilesHoldWhatIsCopied() throws {
        for format in ExportFormat.allCases where format.isCopyable {
            let url = temporaryURL(format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(try ResultExport.write(format, to: url, columns: columns, rows: rows, table: "t").rows == 3)
            #expect(try String(contentsOf: url, encoding: .utf8) == ResultExport.render(format, columns: columns, rows: rows, table: "t"), "\(format)")
        }
    }

    // Used when the catalog does not name the table (schema not loaded in the sidebar).
    @Test func singleSourceTableOfAStatement() {
        let cases: [(String, String?)] = [
            ("select * from shop.orders o order by id", "shop.orders"),
            ("SELECT * FROM \"Mixed Case\" m", "\"Mixed Case\""),
            ("select * from only shop.orders", "shop.orders"),
            ("select id from orders where id in (select 1) limit 5", "orders"),
            ("select * from orders fetch first 5 rows only", "orders"),
            ("select * from a join b on true", nil),
            ("select * from a, b", nil),
            ("select * from (select 1) s", nil),
            ("select * from orders o(a, b)", nil),
            ("with x as (select 1) select * from x", nil),
            ("select 1", nil),
            ("table orders", nil),
            ("select * from db.shop.orders", nil),
        ]
        for (sql, expected) in cases {
            #expect(ResultExport.singleSourceTable(of: sql) == expected, "\(sql)")
        }
    }
}
