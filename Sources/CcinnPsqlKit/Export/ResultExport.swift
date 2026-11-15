import Foundation
import PostgresKit
import PostgresWire

/// Export formats offered by the workbench.
public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, tsv, json, markdown, insert

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .insert: "INSERT statements"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .json: "json"
        case .markdown: "md"
        case .insert: "sql"
        }
    }
}

/// Rendering of result sets in several text formats. Streaming writers keep memory flat for large results.
public enum ResultExport {
    public static func render(_ format: ExportFormat, columns: [ColumnDescription], rows: [[String?]], table: String = "exported") -> String {
        var output = ""
        output.reserveCapacity(rows.count * max(1, columns.count) * 12)
        write(format, columns: columns, rows: rows, table: table) { output += $0 }
        return output
    }

    /// Streams to a file in ~1 MB chunks.
    public static func write(_ format: ExportFormat, to url: URL, columns: [ColumnDescription], rows: [[String?]], table: String = "exported") throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
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
    }

    static func write(_ format: ExportFormat, columns: [ColumnDescription], rows: [[String?]], table: String, emit: (String) -> Void) {
        switch format {
        case .csv: csv(columns: columns, rows: rows, emit: emit)
        case .tsv: emit(tsv(columns: columns, rows: rows))
        case .json: json(columns: columns, rows: rows, emit: emit)
        case .markdown: markdown(columns: columns, rows: rows, emit: emit)
        case .insert: emit(insertStatements(table: table, columns: columns, rows: rows))
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
        let columnList = columns.map { SQLText.identifier($0.name) }.joined(separator: ", ")
        return rows.map { row in
            let values = columns.indices.map { index -> String in
                guard index < row.count, let value = row[index] else { return "NULL" }
                let column = columns[index]
                if column.isNumeric, PostgresText.double(value) != nil { return value }
                if column.kind == .boolean, let flag = PostgresText.bool(value) { return flag ? "true" : "false" }
                return SQLText.literal(value)
            }.joined(separator: ", ")
            return "INSERT INTO \(table) (\(columnList)) VALUES (\(values));"
        }.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
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
