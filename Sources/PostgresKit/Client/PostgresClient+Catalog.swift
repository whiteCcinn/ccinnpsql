import Foundation
import PostgresWire

/// Version-aware catalog SQL (design D9). Pure so the generated statements can be unit-tested per version.
public enum CatalogSQL {
    public static func databases(_ version: ServerVersion) -> String {
        """
        SELECT d.datname, pg_get_userbyid(d.datdba) AS owner, pg_encoding_to_char(d.encoding) AS encoding, d.datcollate,
               d.datallowconn, d.datistemplate, d.datconnlimit, age(d.datfrozenxid) AS xid_age,
               CASE WHEN d.datallowconn AND has_database_privilege(d.datname, 'CONNECT') THEN pg_database_size(d.oid) END AS size_bytes,
               shobj_description(d.oid, 'pg_database') AS comment
        FROM pg_database d ORDER BY d.datistemplate, d.datname
        """
    }

    public static let schemas = """
        SELECT n.nspname, pg_get_userbyid(n.nspowner) AS owner, obj_description(n.oid, 'pg_namespace') AS comment
        FROM pg_namespace n WHERE n.nspname NOT LIKE 'pg\\_temp\\_%' AND n.nspname NOT LIKE 'pg\\_toast\\_temp\\_%'
        ORDER BY n.nspname
        """

    /// SQL that is true when no AccessExclusiveLock is held or awaited on relation `oid`, its TOAST table or its
    /// indexes. The size functions take AccessShareLock: on a relation under (or queued for) DDL they would wait
    /// behind it and make the lock queue longer, stalling the sidebar. Such relations get no size instead.
    public static func sizeIsLockFree(_ oid: String, toast: String? = nil) -> String {
        let locked = """
            coalesce((SELECT array_agg(l.relation) FROM pg_locks l WHERE l.locktype = 'relation' AND l.mode = 'AccessExclusiveLock' \
            AND l.database = (SELECT d.oid FROM pg_database d WHERE d.datname = current_database())), '{}'::oid[])
            """
        var conditions = ["\(oid) <> ALL(\(locked))"]
        if let toast { conditions.append("\(toast) <> ALL(\(locked))") }
        conditions.append("NOT EXISTS (SELECT 1 FROM pg_index li WHERE li.indrelid = \(oid) AND li.indexrelid = ANY(\(locked)))")
        return "(" + conditions.joined(separator: " AND ") + ")"
    }

    /// Relations of schema `$1`.
    public static func relations(_ version: ServerVersion) -> String {
        let partitionColumns = version.atLeast(10)
            ? "c.relispartition, pg_get_expr(c.relpartbound, c.oid) AS partition_bound"
            : "false AS relispartition, NULL::text AS partition_bound"
        return """
        SELECT c.oid::text AS oid, n.nspname AS schema, c.relname AS name, c.relkind::text AS relkind, c.relpersistence::text AS persistence,
               \(partitionColumns), c.relhassubclass, c.reltuples::float8 AS reltuples,
               CASE WHEN c.relkind IN ('r','m','t','f') AND \(sizeIsLockFree("c.oid", toast: "c.reltoastrelid")) THEN pg_total_relation_size(c.oid) END AS total_bytes,
               pg_get_userbyid(c.relowner) AS owner, obj_description(c.oid, 'pg_class') AS comment,
               (SELECT i.inhparent::text FROM pg_inherits i WHERE i.inhrelid = c.oid ORDER BY i.inhseqno LIMIT 1) AS parent_oid
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relkind IN ('r','p','v','m','f','S')
        ORDER BY c.relname
        """
    }

    /// Functions, procedures and aggregates of schema `$1`, excluding members of extensions (PostGIS has thousands).
    public static func routines(_ version: ServerVersion) -> String {
        let kind = version.atLeast(11) ? "p.prokind::text"
            : "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END"
        return """
        SELECT p.oid::text AS oid, n.nspname AS schema, p.proname AS name, \(kind) AS kind,
               pg_get_function_identity_arguments(p.oid) AS arguments,
               CASE WHEN \(kind) = 'p' THEN NULL ELSE pg_get_function_result(p.oid) END AS result,
               l.lanname AS language, p.provolatile::text AS volatility, p.prosecdef AS security_definer,
               obj_description(p.oid, 'pg_proc') AS comment
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_language l ON l.oid = p.prolang
        WHERE n.nspname = $1
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
        ORDER BY p.proname, 5
        """
    }

    /// User-visible types of schema `$1` (no array, table row or extension-owned types).
    public static let types = """
        SELECT t.oid::text AS oid, n.nspname AS schema, t.typname AS name, t.typtype::text AS kind, obj_description(t.oid, 'pg_type') AS comment
        FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = $1 AND t.typtype IN ('b','c','d','e','r','m')
          AND (t.typrelid = 0 OR (SELECT c.relkind = 'c' FROM pg_class c WHERE c.oid = t.typrelid))
          AND NOT (t.typelem <> 0 AND t.typlen = -1 AND t.typname LIKE '\\_%')
          AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
        ORDER BY t.typname
        """

    public static let extensions = """
        SELECT a.name, a.default_version, a.installed_version, n.nspname AS schema, a.comment
        FROM pg_available_extensions a LEFT JOIN pg_extension e ON e.extname = a.name
        LEFT JOIN pg_namespace n ON n.oid = e.extnamespace
        ORDER BY (a.installed_version IS NULL), a.name
        """

    public static func hypertables(extensionVersion: String) -> String {
        if (Int(extensionVersion.split(separator: ".").first ?? "2") ?? 2) >= 2 {
            return "SELECT hypertable_schema AS schema, hypertable_name AS name FROM timescaledb_information.hypertables"
        }
        return "SELECT table_schema AS schema, table_name AS name FROM timescaledb_information.hypertable"
    }

    /// Citus placement of every distributed/reference table (`citus_tables` exists since Citus 10).
    public static let citusTables = """
        SELECT n.nspname AS schema, c.relname AS name,
               CASE p.partmethod WHEN 'n' THEN CASE WHEN p.repmodel = 't' OR p.repmodel = 's' THEN 'reference' ELSE 'local' END ELSE 'distributed' END AS placement,
               CASE WHEN p.partkey IS NOT NULL THEN column_to_column_name(p.logicalrelid, p.partkey) END AS distribution_column
        FROM pg_dist_partition p JOIN pg_class c ON c.oid = p.logicalrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        """
}

extension PostgresClient {
    public func databases() async throws -> [DatabaseSummary] {
        try await records(CatalogSQL.databases(serverInfo.version)).compactMap(CatalogParser.database)
    }

    public func schemas(database: String? = nil) async throws -> [SchemaSummary] {
        try await records(CatalogSQL.schemas, database: database).compactMap { row in
            row.raw("nspname").map { SchemaSummary(name: $0, owner: row.text("owner"), comment: row.string("comment")) }
        }
    }

    /// Relations, routines and types of one schema, with TimescaleDB/Citus markers where those extensions exist.
    public func schemaContents(_ schema: String, database: String? = nil) async throws -> SchemaContents {
        let version = serverInfo.version
        async let relationRows = records(CatalogSQL.relations(version), [.text(schema)], database: database)
        async let routineRows = records(CatalogSQL.routines(version), [.text(schema)], database: database)
        async let typeRows = records(CatalogSQL.types, [.text(schema)], database: database)
        var relations = try await relationRows.compactMap(CatalogParser.relation)
        let routines = try await routineRows.compactMap(CatalogParser.routine)
        let types = try await typeRows.compactMap(CatalogParser.type)
        relations = try await annotateExtensions(relations, database: database)
        return SchemaContents(schema: schema, relations: CatalogParser.withPartitionTotals(relations), routines: routines, types: types)
    }

    /// Column names and types of several `schema.table` pairs at once (completion). Missing tables yield no entry.
    public func columnsByTable(_ tables: [(schema: String, table: String)], database: String? = nil) async throws -> [String: [(name: String, type: String)]] {
        guard !tables.isEmpty else { return [:] }
        let schemas = "{" + tables.map { Self.arrayElement($0.schema) }.joined(separator: ",") + "}"
        let names = "{" + tables.map { Self.arrayElement($0.table) }.joined(separator: ",") + "}"
        let rows = try await records("""
            SELECT n.nspname AS schema, c.relname AS table_name, a.attname, format_type(a.atttypid, a.atttypmod) AS type
            FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN unnest($1::text[], $2::text[]) AS wanted(s, t) ON lower(n.nspname) = lower(wanted.s) AND lower(c.relname) = lower(wanted.t)
            WHERE a.attnum > 0 AND NOT a.attisdropped ORDER BY n.nspname, c.relname, a.attnum
            """, [.text(schemas), .text(names)], database: database)
        var result: [String: [(name: String, type: String)]] = [:]
        for row in rows {
            guard let schema = row.raw("schema"), let table = row.raw("table_name"), let column = row.raw("attname") else { continue }
            result["\(schema).\(table)".lowercased(), default: []].append((column, row.text("type") ?? ""))
        }
        return result
    }

    /// A quoted element of a PostgreSQL text-array literal.
    static func arrayElement(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func extensions(database: String? = nil) async throws -> [ExtensionSummary] {
        try await records(CatalogSQL.extensions, database: database).compactMap { row in
            row.raw("name").map {
                ExtensionSummary(name: $0, installedVersion: row.text("installed_version"), defaultVersion: row.text("default_version"),
                                 schema: row.raw("schema"), comment: row.string("comment"))
            }
        }
    }

    /// Installed extensions of `database` (the server facts only cover the default database).
    public func installedExtensions(database: String? = nil) async throws -> [InstalledExtension] {
        if database == nil || database == defaultDatabase { return serverInfo.extensions }
        return try await records("""
            SELECT e.extname, e.extversion, n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1
            """, database: database).compactMap { row in
            row.raw("extname").map { InstalledExtension(name: $0, version: row.text("extversion") ?? "", schema: row.raw("nspname") ?? "") }
        }
    }

    /// Marks hypertables and Citus tables. Extension queries that fail with a server error are skipped
    /// (privileges, version differences); timeouts and cancellation propagate.
    func annotateExtensions(_ relations: [RelationSummary], database: String?) async throws -> [RelationSummary] {
        let installed = try await installedExtensions(database: database)
        var result = relations
        if let timescale = installed.first(where: { $0.name == "timescaledb" }) {
            do {
                let rows = try await records(CatalogSQL.hypertables(extensionVersion: timescale.version), database: database)
                let names = Set(rows.compactMap { row in row.raw("schema").flatMap { schema in row.raw("name").map { "\(schema).\($0)" } } })
                for index in result.indices where names.contains("\(result[index].schema).\(result[index].name)") {
                    result[index].isHypertable = true
                }
            } catch let error as PostgresError where error.kind == .server {}
        }
        if installed.contains(where: { $0.name == "citus" }) {
            do {
                let rows = try await records(CatalogSQL.citusTables, database: database)
                var placements: [String: (CitusPlacement, String?)] = [:]
                for row in rows {
                    guard let schema = row.raw("schema"), let name = row.raw("name"),
                          let placement = row.text("placement").flatMap(CitusPlacement.init(rawValue:)) else { continue }
                    placements["\(schema).\(name)"] = (placement, row.text("distribution_column"))
                }
                for index in result.indices {
                    if let (placement, column) = placements["\(result[index].schema).\(result[index].name)"] {
                        result[index].citusPlacement = placement
                        result[index].distributionColumn = column
                    }
                }
            } catch let error as PostgresError where error.kind == .server {}
        }
        return result
    }
}

/// Record → model conversions (pure; unit-tested with recorded rows).
public enum CatalogParser {
    public static func database(_ row: Record) -> DatabaseSummary? {
        guard let name = row.raw("datname") else { return nil }
        return DatabaseSummary(name: name, owner: row.text("owner"), encoding: row.text("encoding"), collation: row.text("datcollate"),
                               sizeBytes: row.int("size_bytes"), allowsConnections: row.bool("datallowconn") ?? true,
                               isTemplate: row.bool("datistemplate") ?? false,
                               connectionLimit: row.int("datconnlimit").map { Int(clamping: $0) },
                               transactionIDAge: row.int("xid_age"), comment: row.string("comment"))
    }

    public static func relation(_ row: Record) -> RelationSummary? {
        guard let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let schema = row.raw("schema"), let name = row.raw("name"),
              let kind = row.text("relkind").flatMap(RelationKind.init(rawValue:)) else { return nil }
        let tuples = row.double("reltuples")
        return RelationSummary(oid: oid, schema: schema, name: name, kind: kind, persistence: row.text("persistence") ?? "p",
                               isPartition: row.bool("relispartition") ?? false, partitionBound: row.text("partition_bound"),
                               parentOID: row.int("parent_oid").flatMap { UInt32(exactly: $0) }, hasChildren: row.bool("relhassubclass") ?? false,
                               estimatedRows: tuples.flatMap { $0 < 0 ? nil : Int64(exactly: $0.rounded()) },
                               totalBytes: row.int("total_bytes"), owner: row.text("owner"), comment: row.string("comment"))
    }

    public static func routine(_ row: Record) -> RoutineSummary? {
        guard let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let schema = row.raw("schema"), let name = row.raw("name"),
              let kind = row.text("kind").flatMap(RoutineKind.init(rawValue:)) else { return nil }
        return RoutineSummary(oid: oid, schema: schema, name: name, kind: kind, arguments: row.string("arguments") ?? "",
                              result: row.text("result"), language: row.text("language") ?? "", volatility: row.text("volatility") ?? "v",
                              isSecurityDefiner: row.bool("security_definer") ?? false, comment: row.string("comment"))
    }

    public static func type(_ row: Record) -> TypeSummary? {
        guard let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let schema = row.raw("schema"), let name = row.raw("name"),
              let kind = row.text("kind").flatMap(TypeKind.init(rawValue:)) else { return nil }
        return TypeSummary(oid: oid, schema: schema, name: name, kind: kind, comment: row.string("comment"))
    }

    /// Partitioned tables have no storage: report the sum of their partitions (recursively, cycle-safe).
    public static func withPartitionTotals(_ relations: [RelationSummary]) -> [RelationSummary] {
        let nodes = RelationNode.tree(relations)
        var totals: [UInt32: Int64] = [:]
        func collect(_ node: RelationNode) {
            if node.relation.kind == .partitionedTable, let total = node.totalBytesIncludingChildren { totals[node.relation.oid] = total }
            node.children.forEach(collect)
        }
        nodes.forEach(collect)
        return relations.map { relation in
            guard relation.kind == .partitionedTable, let total = totals[relation.oid] else { return relation }
            return relation.with(totalBytes: total)
        }
    }
}
