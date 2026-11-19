import CryptoKit
import Foundation
import PostgresKit

/// Where extraction reads a schema's structure: `PostgresClient`, or a fake in tests.
public protocol KnowledgeSchemaSource: Sendable {
    var knowledgeServerVersion: String? { get }
    func knowledgeSchema(_ schema: String, database: String?) async throws -> KnowledgeSchemaRows
    func knowledgeServerIdentifier(database: String?) async -> String?
}

extension PostgresClient: KnowledgeSchemaSource {
    public var knowledgeServerVersion: String? { serverInfo.versionString }
}

/// One relation as the server reports it, before it becomes `TableFacts`.
public struct ExtractedTable: Sendable {
    public var name: String
    public var kind: TableFacts.Kind
    public var comment: String?
    public var keys: TableFacts.Keys
    /// In column order.
    public var columns: [ColumnFacts]
    /// The query of a view or materialized view: read for lineage, joins and the fingerprint, never stored.
    public var definition: String?

    public init(name: String, kind: TableFacts.Kind, comment: String? = nil, keys: TableFacts.Keys = TableFacts.Keys(), columns: [ColumnFacts] = [],
                definition: String? = nil) {
        self.name = name
        self.kind = kind
        self.comment = comment
        self.keys = keys
        self.columns = columns
        self.definition = definition
    }
}

/// A declared foreign key of a table in the extracted schema.
public struct ExtractedForeignKey: Sendable, Equatable {
    public var table: String
    public var columns: [String]
    /// The referenced table's schema; may be another schema of the same database.
    public var referencedSchema: String
    public var referencedTable: String
    public var referencedColumns: [String]
    /// Enforced and validated: every row satisfies it. `NOT VALID` and PostgreSQL 18's `NOT ENFORCED` constraints are not.
    public var isGuaranteed: Bool

    public init(table: String, columns: [String], referencedSchema: String, referencedTable: String, referencedColumns: [String], isGuaranteed: Bool) {
        self.table = table
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.isGuaranteed = isGuaranteed
    }
}

/// One schema's structure at one moment. `database` is the schema, as `DatabaseKey.database` is.
public struct ExtractedSchema: Sendable {
    public var database: String
    public var serverVersion: String?
    public var serverIdentifier: String?
    public var tables: [ExtractedTable]
    public var foreignKeys: [ExtractedForeignKey]

    public init(database: String, serverVersion: String?, serverIdentifier: String?, tables: [ExtractedTable], foreignKeys: [ExtractedForeignKey] = []) {
        self.database = database
        self.serverVersion = serverVersion
        self.serverIdentifier = serverIdentifier
        self.tables = tables
        self.foreignKeys = foreignKeys
    }
}

/// Reads one schema in three metadata queries (relations, columns, constraints) plus the server's identifier.
/// Metadata only; no rows.
public enum KnowledgeExtractor {
    public enum Failure: Error, LocalizedError, Equatable {
        case systemSchema(String)

        public var errorDescription: String? {
            switch self {
            case let .systemSchema(name): "“\(name)” is PostgreSQL's own schema; knowledge covers your schemas."
            }
        }
    }

    public static func extract(schema: String, database: String?, from source: some KnowledgeSchemaSource) async throws -> ExtractedSchema {
        guard !KnowledgeSQL.systemSchemas.contains(schema), !schema.hasPrefix("pg_temp_"), !schema.hasPrefix("pg_toast_temp_") else {
            throw Failure.systemSchema(schema)
        }
        async let rows = source.knowledgeSchema(schema, database: database)
        async let identifier = source.knowledgeServerIdentifier(database: database)
        return build(schema: schema, rows: try await rows, serverVersion: source.knowledgeServerVersion, serverIdentifier: await identifier)
    }

    /// Pure: the extracted schema from catalog rows.
    public static func build(schema: String, rows: KnowledgeSchemaRows, serverVersion: String?, serverIdentifier: String?) -> ExtractedSchema {
        var primary: [String: [String]] = [:]
        var unique: [String: [[String]]] = [:]
        var foreignKeys: [ExtractedForeignKey] = []
        for constraint in rows.constraints {
            switch constraint.kind {
            case .primary:
                primary[constraint.table] = constraint.columns
            case .unique:
                unique[constraint.table, default: []].append(constraint.columns)
            case .foreign:
                guard let table = constraint.referencedTable, constraint.columns.count == constraint.referencedColumns.count else { continue }
                foreignKeys.append(ExtractedForeignKey(table: constraint.table, columns: constraint.columns, referencedSchema: constraint.referencedSchema ?? schema,
                                                       referencedTable: table, referencedColumns: constraint.referencedColumns,
                                                       isGuaranteed: constraint.isValidated && constraint.isEnforced))
            }
        }
        let tables = rows.relations.map { (relation: KnowledgeRelationRow) -> ExtractedTable in
            let keyColumns = Set(primary[relation.name] ?? [])
            let columns = (rows.columns[relation.name] ?? []).map { (column: KnowledgeColumnRow) -> ColumnFacts in
                ColumnFacts(name: column.name, type: column.type, isKey: keyColumns.contains(column.name), isNullable: column.isNullable,
                            comment: column.comment?.nilIfEmpty)
            }
            let keys = TableFacts.Keys(primary: primary[relation.name] ?? [], unique: unique[relation.name] ?? [],
                                       partition: KnowledgeSQL.partitionColumns(relation.partitionKey))
            return ExtractedTable(name: relation.name, kind: kind(relation.relkind), comment: relation.comment?.nilIfEmpty, keys: keys, columns: columns,
                                  definition: relation.definition)
        }
        return ExtractedSchema(database: schema, serverVersion: serverVersion, serverIdentifier: serverIdentifier, tables: tables, foreignKeys: foreignKeys)
    }

    static func kind(_ relkind: String) -> TableFacts.Kind {
        switch relkind {
        case "v": .view
        case "m": .materializedView
        case "f": .externalTable
        default: .table
        }
    }
}

/// Fingerprints that say whether knowledge written against a table still describes it.
public enum SchemaFingerprint {
    /// Kind, keys and every column's name, type, nullability and key flag in column order, plus the digest of a view's
    /// query (literals replaced, so a changed date filter is not a new structure). Comments, sizes and row counts are not
    /// part of it.
    public static func structure(kind: TableFacts.Kind, model: String?, keys: TableFacts.Keys, columns: [ColumnFacts], definition: String?) -> String {
        var lines: [String] = ["v1", kind.rawValue, model ?? "-"]
        let uniqueKeys = keys.unique.map { $0.joined(separator: ",") }.joined(separator: ";")
        lines.append([keys.primary.joined(separator: ","), uniqueKeys, keys.partition.joined(separator: ",")].joined(separator: "|"))
        for column in columns {
            let nullability = column.isNullable ? "N" : "NN"
            let key = column.isKey ? "K" : "-"
            lines.append([column.name, column.type.lowercased(), nullability, key].joined(separator: "\t"))
        }
        if let definition { lines.append("q\t" + SQLDigest.digest(definition)) }
        return hash(lines.joined(separator: "\n"))
    }

    /// The table's and its columns' comments: a changed comment refreshes the stored text without making knowledge stale.
    public static func comments(table comment: String?, columns: [ColumnFacts]) -> String {
        let lines: [String] = [comment ?? ""] + columns.map { $0.name + "\t" + ($0.comment ?? "") }
        return hash(lines.joined(separator: "\n"))
    }

    /// 24 hex characters of SHA-256: plenty to detect change, small in every relationship and note that records it.
    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
