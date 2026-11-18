import Foundation
import PostgresKit
import PostgresWire

/// Export formats offered by the workbench.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, tsv, excel, json, markdown, insert, multiRowInsert

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .excel: "Excel"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .insert: "SQL INSERT, One per Row"
        case .multiRowInsert: "SQL INSERT, Multi-row"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .excel: "xlsx"
        case .json: "json"
        case .markdown: "md"
        case .insert, .multiRowInsert: "sql"
        }
    }

    /// Text that can go to the clipboard; an Excel workbook is a file only.
    public var isCopyable: Bool { self != .excel }
}

/// Rendering of result sets in several text formats. Streaming writers keep memory flat for large results.
public enum ResultExport {
    /// Rows and cut cells of a written file.
    public typealias Summary = XLSXWriter.Summary

    /// Rows per multi-row INSERT and its size budget.
    public static let rowsPerStatement = 1_000
    public static let maxStatementBytes = 1 << 20

    public static func render(_ format: ExportFormat, columns: [ColumnDescription], rows: [[String?]], table: String = "exported") -> String {
        var output = ""
        output.reserveCapacity(rows.count * max(1, columns.count) * 12)
        write(format, columns: columns, rows: rows, table: table) { output += $0 }
        return output
    }

    /// Writes `format` to `url`: text streamed in ~1 MB chunks, Excel as a workbook with typed cells. A failed export
    /// leaves no file behind.
    @discardableResult
    public static func write(_ format: ExportFormat, to url: URL, columns: [ColumnDescription], rows: [[String?]], table: String = "exported",
                             sheetName: String = "Result") throws -> Summary {
        if format == .excel {
            return try XLSXWriter.write(to: url, sheetName: sheetName, header: columns.map(\.name), kinds: cellKinds(columns),
                                        rows: spellingBooleans(columns: columns, rows: rows))
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            var buffer = ""
            var failure: (any Error)?
            write(format, columns: columns, rows: rows, table: table) { chunk in
                guard failure == nil else { return }
                buffer += chunk
                if buffer.utf8.count >= 1 << 20 {
                    do { try handle.write(contentsOf: Data(buffer.utf8)) } catch { failure = error }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if let failure { throw failure }
            try handle.write(contentsOf: Data(buffer.utf8))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Summary(rows: rows.count, truncatedCells: 0)
    }

    /// How each column is stored in a workbook: integers and numerics exactly (numerics with their declared scale),
    /// floating point as numbers, the rest as text.
    static func cellKinds(_ columns: [ColumnDescription]) -> [XLSXWriter.CellKind] {
        columns.map { (column: ColumnDescription) -> XLSXWriter.CellKind in
            switch column.kind {
            case .integer: return .integer
            case .decimal: return .decimal(scale: numericScale(column))
            case .float: return .approximateNumber
            default: return .text
            }
        }
    }

    /// The scale of `numeric(p, s)` from its type modifier (`((p << 16) | s) + 4`); `nil` when unconstrained.
    static func numericScale(_ column: ColumnDescription) -> Int? {
        guard column.typeOID == 1700, column.typeModifier >= 4 else { return nil }
        let modifier: Int = Int(column.typeModifier) - 4
        return modifier & 0xFFFF
    }

    /// Booleans as `true` / `false` (the text protocol's `t` / `f`), as in JSON and INSERT exports.
    private static func spellingBooleans(columns: [ColumnDescription], rows: [[String?]]) -> [[String?]] {
        let booleans: [Int] = columns.indices.filter { columns[$0].kind == .boolean }
        guard !booleans.isEmpty else { return rows }
        return rows.map { (row: [String?]) -> [String?] in
            var row = row
            for index in booleans where index < row.count {
                if let value = row[index], let flag = PostgresText.bool(value) { row[index] = flag ? "true" : "false" }
            }
            return row
        }
    }

    static func write(_ format: ExportFormat, columns: [ColumnDescription], rows: [[String?]], table: String, emit: (String) -> Void) {
        switch format {
        case .csv: csv(columns: columns, rows: rows, emit: emit)
        case .tsv: emit(tsv(columns: columns, rows: rows))
        case .json: json(columns: columns, rows: rows, emit: emit)
        case .markdown: markdown(columns: columns, rows: rows, emit: emit)
        case .insert: emit(insertStatements(table: table, columns: columns, rows: rows))
        case .multiRowInsert:
            multiRowInsert(table: table, columns: columns, rows: rows, rowsPerStatement: rowsPerStatement, maxStatementBytes: maxStatementBytes, emit: emit)
        case .excel: break
        }
    }

    // MARK: CSV

    /// RFC 4180 CSV. Text cells a spreadsheet would evaluate as a formula (`=`, `+`, `-`, `@`, tab, CR) get a `'`
    /// prefix; numeric columns are left untouched so negative numbers survive. NULL is an empty field.
    public static func csv(columns: [ColumnDescription], rows: [[String?]], includeHeader: Bool = true) -> String {
        var output = ""
        csv(columns: columns, rows: rows, includeHeader: includeHeader) { output += $0 }
        return output
    }

    static func csv(columns: [ColumnDescription], rows: [[String?]], includeHeader: Bool = true, emit: (String) -> Void) {
        let numeric = columns.map(\.isNumeric)
        if includeHeader { emit(columns.map { escapeCSV($0.name, neutralize: true) }.joined(separator: ",") + "\r\n") }
        for row in rows {
            var line = ""
            for index in columns.indices {
                if index > 0 { line += "," }
                guard index < row.count, let value = row[index] else { continue }
                line += escapeCSV(value, neutralize: !numeric[index])
            }
            emit(line + "\r\n")
        }
    }

    static func escapeCSV(_ value: String, neutralize: Bool) -> String {
        var value = value
        if neutralize, let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || value != value.trimmingCharacters(in: .whitespaces) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: TSV

    /// Tab-separated text for the clipboard (pastes into spreadsheets); NULL becomes empty.
    public static func tsv(columns: [ColumnDescription], rows: [[String?]], includeHeader: Bool = true) -> String {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        if includeHeader { lines.append(columns.map { cleanTSV($0.name) }.joined(separator: "\t")) }
        for row in rows {
            lines.append(columns.indices.map { index in index < row.count ? cleanTSV(row[index] ?? "") : "" }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    static func cleanTSV(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) else { return value }
        return value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: JSON

    /// An array of objects; numbers and booleans keep their JSON type, json/jsonb values are embedded as JSON.
    static func json(columns: [ColumnDescription], rows: [[String?]], emit: (String) -> Void) {
        emit("[")
        for (rowIndex, row) in rows.enumerated() {
            var members: [String] = []
            for (index, column) in columns.enumerated() {
                let value = index < row.count ? row[index] : nil
                members.append(JSONValue.string(column.name).serialized() + ":" + jsonValue(value, column: column))
            }
            emit((rowIndex == 0 ? "\n  {" : ",\n  {") + members.joined(separator: ",") + "}")
        }
        emit(rows.isEmpty ? "]\n" : "\n]\n")
    }

    static func jsonValue(_ value: String?, column: ColumnDescription) -> String {
        guard let value else { return "null" }
        switch column.kind {
        case .integer:
            if Int64(value) != nil { return value }
        case .float, .decimal:
            if let number = PostgresText.double(value), number.isFinite { return value.hasPrefix(".") ? "0" + value : value }
        case .boolean:
            if let flag = PostgresText.bool(value) { return flag ? "true" : "false" }
        case .json:
            if (try? JSONValue.parse(value)) != nil { return value.replacingOccurrences(of: "\n", with: " ") }
        default:
            break
        }
        return JSONValue.string(value).serialized()
    }

    // MARK: Markdown

    static func markdown(columns: [ColumnDescription], rows: [[String?]], emit: (String) -> Void) {
        func cell(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>")
        }
        emit("| " + columns.map { cell($0.name) }.joined(separator: " | ") + " |\n")
        emit("|" + columns.map { $0.isNumeric ? " ---: |" : " --- |" }.joined() + "\n")
        for row in rows {
            emit("| " + columns.indices.map { index in index < row.count ? cell(row[index] ?? "NULL") : "" }.joined(separator: " | ") + " |\n")
        }
    }

    // MARK: INSERT

    /// `INSERT INTO t (…) VALUES (…);` per row with standard-conforming literals.
    public static func insertStatements(table: String, columns: [ColumnDescription], rows: [[String?]]) -> String {
        let list = columnList(columns)
        return rows.map { (row: [String?]) -> String in
            "INSERT INTO \(table) (\(list)) VALUES \(tuple(row, columns: columns));"
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    }

    /// `INSERT INTO t (…) VALUES` with one row per line. A new statement starts every `rowsPerStatement` rows, or
    /// before a row that would take the statement past `maxStatementBytes`.
    public static func multiRowInsert(table: String, columns: [ColumnDescription], rows: [[String?]], rowsPerStatement: Int = rowsPerStatement,
                                      maxStatementBytes: Int = maxStatementBytes) -> String {
        var output = ""
        multiRowInsert(table: table, columns: columns, rows: rows, rowsPerStatement: rowsPerStatement, maxStatementBytes: maxStatementBytes) {
            output += $0
        }
        return output
    }

    private static func multiRowInsert(table: String, columns: [ColumnDescription], rows: [[String?]], rowsPerStatement: Int,
                                       maxStatementBytes: Int, emit: (String) -> Void) {
        let head = "INSERT INTO \(table) (\(columnList(columns))) VALUES"
        let rowsPerStatement = max(1, rowsPerStatement)
        var rowsInStatement = 0
        var statementBytes = 0
        for row in rows {
            let values = tuple(row, columns: columns)
            let rowBytes: Int = 4 + values.utf8.count // ",\n  " or "\n  "
            let isFull: Bool = rowsInStatement >= rowsPerStatement
            let wouldOverflow: Bool = statementBytes + rowBytes + 1 > maxStatementBytes
            if rowsInStatement > 0, isFull || wouldOverflow {
                emit(";\n")
                rowsInStatement = 0
            }
            if rowsInStatement == 0 {
                emit(head)
                statementBytes = head.utf8.count
            }
            emit((rowsInStatement == 0 ? "\n  " : ",\n  ") + values)
            statementBytes += rowBytes
            rowsInStatement += 1
        }
        if rowsInStatement > 0 { emit(";\n") }
    }

    private static func columnList(_ columns: [ColumnDescription]) -> String {
        columns.map { SQLText.identifier($0.name) }.joined(separator: ", ")
    }

    /// `(1, 'text', true, NULL)`: finite numbers and booleans bare, everything else (NaN and Infinity included, which
    /// PostgreSQL would read as names) as a standard-conforming literal.
    private static func tuple(_ row: [String?], columns: [ColumnDescription]) -> String {
        "(" + columns.indices.map { (index: Int) -> String in
            guard index < row.count, let value = row[index] else { return "NULL" }
            let column = columns[index]
            if column.isNumeric, let number = PostgresText.double(value), number.isFinite { return value }
            if column.kind == .boolean, let flag = PostgresText.bool(value) { return flag ? "true" : "false" }
            return SQLText.literal(value)
        }.joined(separator: ", ") + ")"
    }

    /// The single relation a plain `SELECT … FROM [ONLY] [schema.]t [[AS] alias] …` reads, quoted as needed. `nil` for
    /// joins, comma lists, derived tables, column alias lists, CTEs, set operations and three-part names. Used when the
    /// catalog does not name the table.
    public static func singleSourceTable(of sql: String) -> String? {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        let words: [String] = tokens.map { (token: SQLToken) -> String in token.kind == .keyword ? lexer.text(of: token).uppercased() : "" }
        guard words.first == "SELECT" else { return nil }
        func isPunctuation(_ index: Int, _ text: String) -> Bool {
            guard tokens[index].kind == .punctuation else { return false }
            return lexer.text(of: tokens[index]) == text
        }
        func isName(_ index: Int) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier: return true
            case .keyword: return !SQLKeywords.reserved.contains(words[index])
            default: return false
            }
        }
        var depth = 0
        var from: Int?
        for index in tokens.indices {
            if isPunctuation(index, "(") { depth += 1 }
            if isPunctuation(index, ")") { depth -= 1 }
            guard depth == 0 else { continue }
            switch words[index] {
            case "FROM":
                guard from == nil else { return nil }
                from = index
            case "JOIN", "UNION", "INTERSECT", "EXCEPT", "LATERAL": return nil
            default: break
            }
        }
        guard let from else { return nil }
        var index = from + 1
        if index < tokens.count, words[index] == "ONLY" { index += 1 }
        var parts: [String] = []
        while index < tokens.count, isName(index) {
            parts.append(lexer.identifierValue(of: tokens[index]))
            index += 1
            guard index + 1 < tokens.count, isPunctuation(index, ".") else { break }
            index += 1
        }
        guard (1...2).contains(parts.count) else { return nil }
        if index < tokens.count, words[index] == "AS" { index += 1 }
        let clauseWords: Set<String> = ["WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "WINDOW", "FOR", "TABLESAMPLE"]
        if index < tokens.count, isName(index), !clauseWords.contains(words[index]) { index += 1 }
        if index == tokens.count || isPunctuation(index, ";") { return SQLText.qualified(parts.count == 2 ? parts[0] : nil, parts[parts.count - 1]) }
        guard clauseWords.contains(words[index]) else { return nil }
        return SQLText.qualified(parts.count == 2 ? parts[0] : nil, parts[parts.count - 1])
    }

    /// `COPY (query) TO STDOUT WITH (FORMAT csv, HEADER)` for full exports streamed from the server. The query
    /// ends on its own line so a trailing `-- comment` cannot swallow the closing parenthesis.
    public static func copyStatement(for query: String) -> String {
        var body = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") {
            body.removeLast()
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "COPY (\(body)\n) TO STDOUT WITH (FORMAT csv, HEADER)"
    }
}
