import Foundation
import PostgresWire

/// A result column (from RowDescription), with its type name when known.
public struct ColumnDescription: Sendable, Equatable {
    public var name: String
    public var typeOID: UInt32
    /// `pg_type` name (`int4`, `varchar`, `geometry`); built-ins are known locally, others are resolved by the client.
    public var typeName: String?
    public var typeModifier: Int32
    public var tableOID: UInt32
    public var columnNumber: Int16
    public var format: FormatCode

    public init(name: String, typeOID: UInt32, typeName: String? = nil, typeModifier: Int32 = -1, tableOID: UInt32 = 0,
                columnNumber: Int16 = 0, format: FormatCode = .text) {
        self.name = name
        self.typeOID = typeOID
        self.typeName = typeName ?? PostgresType.name(of: typeOID)
        self.typeModifier = typeModifier
        self.tableOID = tableOID
        self.columnNumber = columnNumber
        self.format = format
    }

    init(_ field: FieldDescription, format: FormatCode) {
        self.init(name: field.name, typeOID: field.typeOID, typeModifier: field.typeModifier, tableOID: field.tableOID,
                  columnNumber: field.columnNumber, format: format)
    }

    public var kind: PostgresType.Kind {
        let builtin = PostgresType.kind(of: typeOID)
        if builtin == .text, let typeName, typeName.hasPrefix("_") { return .array }
        return builtin
    }

    public var isNumeric: Bool {
        switch kind {
        case .integer, .float, .decimal: true
        default: false
        }
    }

    /// Type with modifiers as `format_type` prints common cases (`varchar(20)`, `numeric(10,2)`, `timestamp(3)`).
    public var displayType: String {
        let base = typeName.map { $0.hasPrefix("_") ? String($0.dropFirst()) + "[]" : $0 } ?? "oid \(typeOID)"
        guard typeModifier >= 0 else { return base }
        switch typeOID {
        case 1043, 1042, 1560, 1562: // varchar, bpchar, bit, varbit (typmod includes the 4-byte header for character types)
            let length = typeOID == 1043 || typeOID == 1042 ? Int(typeModifier) - 4 : Int(typeModifier)
            return length > 0 ? "\(base)(\(length))" : base
        case 1700:
            let value = Int(typeModifier) - 4
            guard value >= 0 else { return base }
            return "\(base)(\((value >> 16) & 0xFFFF),\(value & 0xFFFF))"
        case 1083, 1114, 1184, 1266:
            return "\(base)(\(typeModifier))"
        default:
            return base
        }
    }
}

/// Case-insensitive column-name → index map shared by every record of a result.
public struct ColumnLookup: Sendable, Equatable {
    private let indices: [String: Int]
    public let names: [String]

    public init(names: [String]) {
        self.names = names
        var indices: [String: Int] = [:]
        indices.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let key = name.lowercased()
            if indices[key] == nil { indices[key] = index }
        }
        self.indices = indices
    }

    /// Index of the first of `names` that exists (alternatives cover renamed columns across versions).
    public func index(of names: [String]) -> Int? {
        for name in names {
            if let index = indices[name.lowercased()] { return index }
        }
        return nil
    }
}

/// One row with access by column name (design D9: never by position for metadata).
public struct Record: Sendable {
    public let values: [String?]
    let lookup: ColumnLookup

    public init(values: [String?], lookup: ColumnLookup) {
        self.values = values
        self.lookup = lookup
    }

    public init(_ pairs: KeyValuePairs<String, String?>) {
        values = pairs.map(\.value)
        lookup = ColumnLookup(names: pairs.map(\.key))
    }

    /// Raw value of the first existing column among `names`; `nil` when missing or SQL NULL.
    public func raw(_ names: String...) -> String? { raw(names) }

    public func raw(_ names: [String]) -> String? {
        guard let index = lookup.index(of: names), index < values.count else { return nil }
        return values[index]
    }

    public func has(_ name: String) -> Bool { lookup.index(of: [name]) != nil }

    /// Trimmed text; `nil` for missing, SQL NULL and empty values.
    public func text(_ names: String...) -> String? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Text without trimming (definitions, queries); `nil` only for missing or NULL.
    public func string(_ names: String...) -> String? { raw(names) }

    public func int(_ names: String...) -> Int64? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return PostgresText.integer(value) ?? PostgresText.double(value).flatMap { $0.rounded() == $0 && abs($0) < 9.2e18 ? Int64($0) : nil }
    }

    public func double(_ names: String...) -> Double? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return PostgresText.double(value)
    }

    public func bool(_ names: String...) -> Bool? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return PostgresText.bool(value)
    }

    public func date(_ names: String...) -> Date? {
        guard let value = raw(names)?.trimmingCharacters(in: .whitespaces) else { return nil }
        return PostgresText.dateTime(value)
    }

    /// PostgreSQL text arrays (`{a,b,"c d"}`) of simple values.
    public func array(_ names: String...) -> [String] {
        guard let value = raw(names) else { return [] }
        return PostgresArray.parse(value)
    }
}

/// One result of a statement: a row set (when a RowDescription was received) or a command tag.
public struct ResultSet: Sendable {
    public let columns: [ColumnDescription]
    public let rows: [[String?]]
    public let commandTag: CommandTag?
    /// More rows existed than the configured limit; they were not kept.
    public let isTruncated: Bool
    public let hasRowSet: Bool
    public let lookup: ColumnLookup

    public init(columns: [ColumnDescription], rows: [[String?]], commandTag: CommandTag? = nil, isTruncated: Bool = false,
                hasRowSet: Bool = true) {
        self.columns = columns
        self.rows = rows
        self.commandTag = commandTag
        self.isTruncated = isTruncated
        self.hasRowSet = hasRowSet
        lookup = ColumnLookup(names: columns.map(\.name))
    }

    public static func command(_ tag: CommandTag) -> ResultSet {
        ResultSet(columns: [], rows: [], commandTag: tag, hasRowSet: false)
    }

    public var columnNames: [String] { columns.map(\.name) }
    /// Rows affected (INSERT/UPDATE/DELETE/MERGE/COPY) or returned (SELECT) according to the command tag.
    public var affectedRows: Int? { commandTag?.rowCount }

    public func record(at index: Int) -> Record? {
        guard rows.indices.contains(index) else { return nil }
        return Record(values: rows[index], lookup: lookup)
    }

    public var records: [Record] { rows.map { Record(values: $0, lookup: lookup) } }
    public var first: Record? { record(at: 0) }

    /// First column of the first row (scalar queries).
    public var scalar: String? { rows.first?.first ?? nil }

    func with(columns newColumns: [ColumnDescription]) -> ResultSet {
        ResultSet(columns: newColumns, rows: rows, commandTag: commandTag, isTruncated: isTruncated, hasRowSet: hasRowSet)
    }
}

/// Everything one command produced.
public struct QueryResult: Sendable {
    public var results: [ResultSet]
    public var notices: [ServerMessageFields]
    public var notifications: [NotificationMessage]
    public var transactionStatus: TransactionStatus
    /// ParameterStatus changes reported while the command ran (`TimeZone`, `search_path` on PostgreSQL 18, …).
    public var parameterChanges: [String: String]
    /// Statements that completed (CommandComplete), in a simple-protocol batch.
    public var completedStatements: Int
    /// Skipping rows past the row limit took too long and the statement was cancelled: the server rolled back
    /// what the batch had not committed (or aborted the open transaction), and later statements did not run.
    public var cancelledAtRowLimit: Bool

    public init(results: [ResultSet] = [], notices: [ServerMessageFields] = [], notifications: [NotificationMessage] = [],
                transactionStatus: TransactionStatus = .idle, parameterChanges: [String: String] = [:], completedStatements: Int = 0,
                cancelledAtRowLimit: Bool = false) {
        self.results = results
        self.notices = notices
        self.notifications = notifications
        self.transactionStatus = transactionStatus
        self.parameterChanges = parameterChanges
        self.completedStatements = completedStatements
        self.cancelledAtRowLimit = cancelledAtRowLimit
    }

    /// The last result (scalar and metadata helpers use it).
    public var last: ResultSet? { results.last }
    /// The last result that carries rows.
    public var lastRowSet: ResultSet? { results.last(where: \.hasRowSet) }
    public var records: [Record] { lastRowSet?.records ?? [] }
}

/// Bounds applied while reading rows (design D5).
public struct RowLimits: Sendable, Equatable {
    /// Rows kept per result set.
    public var maxRows: Int
    /// Bytes of row payload kept per result set.
    public var maxBytes: Int
    /// Rows past the limit are read and discarded so the statement (and its batch or transaction) completes
    /// normally; a cancel would roll back what the batch had not committed. Only after `drainRows` discarded rows
    /// or `drainSeconds` of skipping is the statement cancelled (the cancel's grace period then bounds the rest).
    public var drainRows: Int
    public var drainSeconds: Double

    public init(maxRows: Int = 100_000, maxBytes: Int = 512 * 1024 * 1024, drainRows: Int = 10_000_000, drainSeconds: Double = 15) {
        self.maxRows = max(0, maxRows)
        self.maxBytes = max(0, maxBytes)
        self.drainRows = max(0, drainRows)
        self.drainSeconds = drainSeconds.isFinite ? max(0, drainSeconds) : 15
    }

    public static let metadata = RowLimits(maxRows: 200_000, maxBytes: 256 * 1024 * 1024)
}

/// Result wire format for extended queries.
public enum ResultFormat: Sendable, Equatable {
    case text
    /// Binary for columns whose type has a decoder (needs a Describe round trip); text otherwise.
    case binaryWhereSupported
}

/// Minimal parser for one-dimensional PostgreSQL array text (`{a,"b c",NULL}`); NULL elements are skipped.
public enum PostgresArray {
    public static func parse(_ text: String) -> [String] {
        var characters = Substring(text.trimmingCharacters(in: .whitespaces))
        guard characters.first == "{", characters.last == "}" else { return [] }
        characters = characters.dropFirst().dropLast()
        var elements: [String] = []
        var current = ""
        var quoted = false
        var wasQuoted = false
        var escape = false
        for character in characters {
            if escape {
                current.append(character)
                escape = false
            } else if character == "\\" {
                escape = true
            } else if character == "\"" {
                quoted.toggle()
                wasQuoted = true
            } else if character == ",", !quoted {
                if wasQuoted || current != "NULL" { elements.append(current) }
                current = ""
                wasQuoted = false
            } else {
                current.append(character)
            }
            if elements.count > 100_000 { break }
        }
        if !characters.isEmpty, wasQuoted || current != "NULL" { elements.append(current) }
        return elements
    }
}
