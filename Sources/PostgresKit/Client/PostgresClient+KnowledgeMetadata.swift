import Foundation
import PostgresWire

/// One relation of a schema as knowledge extraction reads it: tables, partitioned tables, views, materialized views and
/// foreign tables (partitions are left out: their parent stands for them).
public struct KnowledgeRelationRow: Sendable, Equatable {
    public var name: String
    /// `r` table, `p` partitioned table, `v` view, `m` materialized view, `f` foreign table.
    public var relkind: String
    public var comment: String?
    /// `pg_get_partkeydef`: `RANGE (created_at)`.
    public var partitionKey: String?
    /// The query of a view or materialized view, read for lineage and joins, never stored.
    public var definition: String?

    public init(name: String, relkind: String, comment: String? = nil, partitionKey: String? = nil, definition: String? = nil) {
        self.name = name
        self.relkind = relkind
        self.comment = comment
        self.partitionKey = partitionKey
        self.definition = definition
    }
}

public struct KnowledgeColumnRow: Sendable, Equatable {
    public var table: String
    public var name: String
    /// `format_type`: `character varying(64)`, `numeric(12,2)`.
    public var type: String
    public var isNullable: Bool
    public var comment: String?

    public init(table: String, name: String, type: String, isNullable: Bool, comment: String? = nil) {
        self.table = table
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.comment = comment
    }
}

/// A primary key, unique or foreign key constraint.
public struct KnowledgeConstraintRow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case primary = "p", unique = "u", foreign = "f"
    }

    public var table: String
    public var kind: Kind
    public var columns: [String]
    public var referencedSchema: String?
    public var referencedTable: String?
    public var referencedColumns: [String]
    /// False for a foreign key added `NOT VALID` and not validated since: existing rows may break it.
    public var isValidated: Bool
    /// False for PostgreSQL 18's `NOT ENFORCED` constraints: declared, never checked.
    public var isEnforced: Bool

    public init(table: String, kind: Kind, columns: [String], referencedSchema: String? = nil, referencedTable: String? = nil,
                referencedColumns: [String] = [], isValidated: Bool = true, isEnforced: Bool = true) {
        self.table = table
        self.kind = kind
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.isValidated = isValidated
        self.isEnforced = isEnforced
    }
}

/// A schema's structure in three metadata queries, whatever its size.
public struct KnowledgeSchemaRows: Sendable, Equatable {
    public var relations: [KnowledgeRelationRow]
    /// Per table, in column order.
    public var columns: [String: [KnowledgeColumnRow]]
    public var constraints: [KnowledgeConstraintRow]

    public init(relations: [KnowledgeRelationRow], columns: [String: [KnowledgeColumnRow]], constraints: [KnowledgeConstraintRow]) {
        self.relations = relations
        self.columns = columns
        self.constraints = constraints
    }
}

/// Version-aware SQL for knowledge extraction (schema `$1`). Pure so each version's statements can be tested.
public enum KnowledgeSQL {
    public static func relations(_ version: ServerVersion) -> String {
        let partitions = version.atLeast(10)
            ? "CASE WHEN c.relkind = 'p' THEN pg_catalog.pg_get_partkeydef(c.oid) END AS partition_key"
            : "NULL::text AS partition_key"
        let notPartition = version.atLeast(10) ? "AND NOT c.relispartition" : ""
        return """
        SELECT c.relname AS name, c.relkind::text AS relkind, pg_catalog.obj_description(c.oid, 'pg_class') AS comment, \(partitions),
               CASE WHEN c.relkind IN ('v','m') THEN pg_catalog.pg_get_viewdef(c.oid, true) END AS definition
        FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f') \(notPartition)
        ORDER BY c.relname
        """
    }

    public static func columns(_ version: ServerVersion) -> String {
        let notPartition = version.atLeast(10) ? "AND NOT c.relispartition" : ""
        return """
        SELECT c.relname AS table_name, a.attname AS name, pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
               a.attnotnull AS not_null, pg_catalog.col_description(a.attrelid, a.attnum) AS comment
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f') \(notPartition) AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY c.relname, a.attnum
        """
    }

    public static func constraints(_ version: ServerVersion) -> String {
        let enforced = version.atLeast(18) ? "k.conenforced" : "true"
        let notPartition = version.atLeast(10) ? "AND NOT c.relispartition" : ""
        return """
        SELECT c.relname AS table_name, k.contype::text AS kind, k.convalidated AS validated, \(enforced) AS enforced,
               ARRAY(SELECT a.attname FROM unnest(k.conkey) WITH ORDINALITY AS u(attnum, position)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = u.attnum ORDER BY u.position)::text[] AS columns,
               rn.nspname AS referenced_schema, r.relname AS referenced_table,
               ARRAY(SELECT a.attname FROM unnest(k.confkey) WITH ORDINALITY AS u(attnum, position)
                     JOIN pg_catalog.pg_attribute a ON a.attrelid = k.confrelid AND a.attnum = u.attnum ORDER BY u.position)::text[] AS referenced_columns
        FROM pg_catalog.pg_constraint k
        JOIN pg_catalog.pg_class c ON c.oid = k.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN pg_catalog.pg_class r ON r.oid = k.confrelid
        LEFT JOIN pg_catalog.pg_namespace rn ON rn.oid = r.relnamespace
        WHERE n.nspname = $1 AND k.contype IN ('p','u','f') \(notPartition)
        ORDER BY c.relname, k.conname
        """
    }

    /// Relations of schema `$1` the current role may read (any column counts). Knowledge shown to an AI is limited to these.
    public static let visibleRelations = """
        SELECT c.relname AS name FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND c.relkind IN ('r','p','v','m','f')
          AND (pg_catalog.has_table_privilege(c.oid, 'SELECT') OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT'))
        """

    /// Schemas of the database the current role may use, without PostgreSQL's own.
    public static let visibleSchemas = """
        SELECT n.nspname AS name FROM pg_catalog.pg_namespace n
        WHERE pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
          AND n.nspname NOT LIKE 'pg\\_temp\\_%' AND n.nspname NOT LIKE 'pg\\_toast\\_temp\\_%'
        ORDER BY n.nspname
        """

    /// The same on every replica of one server, so it can suggest that two endpoints are one server.
    public static let serverIdentifier = "SELECT system_identifier::text AS identifier FROM pg_catalog.pg_control_system()"

    /// PostgreSQL's own schemas: never a subject of knowledge.
    public static let systemSchemas: Set<String> = ["pg_catalog", "information_schema", "pg_toast"]

    /// `RANGE (created_at, region)` → ["created_at", "region"]; expressions keep their text.
    public static func partitionColumns(_ definition: String?) -> [String] {
        guard let definition, let open = definition.firstIndex(of: "("), let close = definition.lastIndex(of: ")"), open < close else { return [] }
        let inner = definition[definition.index(after: open)..<close]
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in inner {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if character == ",", depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.filter { !$0.isEmpty }
    }

    // MARK: Parsing

    static func relation(_ row: Record) -> KnowledgeRelationRow? {
        guard let name = row.raw("name"), let relkind = row.text("relkind") else { return nil }
        return KnowledgeRelationRow(name: name, relkind: relkind, comment: row.string("comment"), partitionKey: row.text("partition_key"),
                                    definition: row.text("definition"))
    }

    static func column(_ row: Record) -> KnowledgeColumnRow? {
        guard let table = row.raw("table_name"), let name = row.raw("name") else { return nil }
        return KnowledgeColumnRow(table: table, name: name, type: row.text("type") ?? "", isNullable: !(row.bool("not_null") ?? false),
                                  comment: row.string("comment"))
    }

    static func constraint(_ row: Record) -> KnowledgeConstraintRow? {
        guard let table = row.raw("table_name"), let raw = row.text("kind"), let kind = KnowledgeConstraintRow.Kind(rawValue: raw) else { return nil }
        let columns = row.array("columns")
        guard !columns.isEmpty else { return nil }
        return KnowledgeConstraintRow(table: table, kind: kind, columns: columns, referencedSchema: row.raw("referenced_schema"),
                                      referencedTable: row.raw("referenced_table"), referencedColumns: row.array("referenced_columns"),
                                      isValidated: row.bool("validated") ?? true, isEnforced: row.bool("enforced") ?? true)
    }
}

extension PostgresClient {
    /// The structure of `schema` in `database` (the connection's database when nil). Metadata only; no rows are read.
    public func knowledgeSchema(_ schema: String, database: String? = nil) async throws -> KnowledgeSchemaRows {
        let version = serverInfo.version
        async let relationRows = records(KnowledgeSQL.relations(version), [.text(schema)], database: database)
        async let columnRows = records(KnowledgeSQL.columns(version), [.text(schema)], database: database)
        async let constraintRows = records(KnowledgeSQL.constraints(version), [.text(schema)], database: database)
        let relations = try await relationRows.compactMap(KnowledgeSQL.relation)
        var columns: [String: [KnowledgeColumnRow]] = [:]
        for column in try await columnRows.compactMap(KnowledgeSQL.column) { columns[column.table, default: []].append(column) }
        let constraints = try await constraintRows.compactMap(KnowledgeSQL.constraint)
        return KnowledgeSchemaRows(relations: relations, columns: columns, constraints: constraints)
    }

    /// Names of the relations of `schema` the current role may read.
    public func knowledgeVisibleRelations(_ schema: String, database: String? = nil) async throws -> Set<String> {
        Set(try await records(KnowledgeSQL.visibleRelations, [.text(schema)], database: database).compactMap { $0.raw("name") })
    }

    /// Schemas of `database` the current role may use.
    public func knowledgeVisibleSchemas(database: String? = nil) async throws -> [String] {
        try await records(KnowledgeSQL.visibleSchemas, database: database).compactMap { $0.raw("name") }
    }

    /// `system_identifier`, or nil when the server refuses (the function needs a privilege on some installations).
    public func knowledgeServerIdentifier(database: String? = nil) async -> String? {
        guard !serverInfo.isPgBouncerConsole else { return nil }
        return try? await records(KnowledgeSQL.serverIdentifier, database: database).first?.text("identifier")
    }
}
