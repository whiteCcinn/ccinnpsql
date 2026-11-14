import Foundation
import PostgresWire

/// Version-aware SQL for table insights (design D9). `$1` is always the relation OID as text.
public enum InsightSQL {
    public static func columns(_ version: ServerVersion) -> String {
        let identity = version.atLeast(10) ? "a.attidentity::text" : "''::text"
        let generated = version.atLeast(12) ? "a.attgenerated::text" : "''::text"
        return """
        SELECT a.attnum, a.attname, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull, a.attislocal,
               pg_get_expr(ad.adbin, ad.adrelid) AS default_expr, \(identity) AS identity, \(generated) AS generated,
               CASE WHEN a.attcollation <> t.typcollation THEN co.collname END AS collation,
               col_description(a.attrelid, a.attnum) AS comment, st.null_frac, st.n_distinct, st.avg_width
        FROM pg_attribute a
        JOIN pg_type t ON t.oid = a.atttypid
        LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
        LEFT JOIN pg_collation co ON co.oid = a.attcollation
        LEFT JOIN pg_class c ON c.oid = a.attrelid
        LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
        LEFT JOIN LATERAL (
            SELECT s.null_frac, s.n_distinct, s.avg_width FROM pg_stats s
            WHERE s.schemaname = n.nspname AND s.tablename = c.relname AND s.attname = a.attname
            ORDER BY s.inherited LIMIT 1
        ) st ON true
        WHERE a.attrelid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }

    public static let constraints = """
        SELECT c.conname, c.contype::text AS contype, pg_get_constraintdef(c.oid, true) AS definition, c.condeferrable,
               c.convalidated, c.conislocal, CASE WHEN c.confrelid <> 0 THEN c.confrelid::regclass::text END AS referenced
        FROM pg_constraint c WHERE c.conrelid = $1::oid
        ORDER BY CASE c.contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 WHEN 'c' THEN 3 ELSE 4 END, c.conname
        """

    public static func indexes(_ version: ServerVersion) -> String {
        let lastScan = version.atLeast(16) ? "s.last_idx_scan" : "NULL::timestamptz"
        return """
        SELECT i.indexrelid::text AS oid, ic.relname AS name, pg_get_indexdef(i.indexrelid) AS definition, am.amname AS method,
               i.indisunique, i.indisprimary, i.indisvalid, i.indkey::text AS indkey,
               (SELECT con.conname FROM pg_constraint con WHERE con.conindid = i.indexrelid AND con.conrelid = i.indrelid LIMIT 1) AS constraint_name,
               pg_relation_size(i.indexrelid) AS size_bytes, s.idx_scan, s.idx_tup_read, s.idx_tup_fetch,
               ic.reltuples::float8 AS reltuples, ic.relpages::bigint AS relpages, \(lastScan) AS last_scan,
               (SELECT split_part(o, '=', 2) FROM unnest(ic.reloptions) o WHERE o LIKE 'fillfactor=%' LIMIT 1) AS fillfactor
        FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid JOIN pg_am am ON am.oid = ic.relam
        LEFT JOIN pg_stat_all_indexes s ON s.indexrelid = i.indexrelid
        WHERE i.indrelid = $1::oid
        ORDER BY i.indisprimary DESC, ic.relname
        """
    }

    public static let triggers = """
        SELECT t.tgname, pg_get_triggerdef(t.oid, true) AS definition, t.tgenabled::text AS enabled, p.proname AS function
        FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE t.tgrelid = $1::oid AND NOT t.tgisinternal ORDER BY t.tgname
        """

    public static func children(_ version: ServerVersion) -> String {
        let bound = version.atLeast(10) ? "pg_get_expr(c.relpartbound, c.oid)" : "NULL::text"
        return """
        SELECT c.oid::text AS oid, n.nspname AS schema, c.relname AS name, \(bound) AS bound, c.relkind::text AS relkind,
               CASE WHEN c.relkind IN ('r','m','f') THEN pg_total_relation_size(c.oid) END AS total_bytes, c.reltuples::float8 AS reltuples
        FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE i.inhparent = $1::oid ORDER BY c.relname
        """
    }

    public static func partitioning(_ version: ServerVersion) -> String {
        let key = version.atLeast(10) ? "CASE WHEN c.relkind = 'p' THEN pg_get_partkeydef(c.oid) END" : "NULL::text"
        return """
        SELECT \(key) AS partition_key,
               (SELECT i.inhparent::regclass::text FROM pg_inherits i WHERE i.inhrelid = c.oid ORDER BY i.inhseqno LIMIT 1) AS parent
        FROM pg_class c WHERE c.oid = $1::oid
        """
    }

    public static func statistics(_ version: ServerVersion) -> String {
        let sinceVacuum = version.atLeast(13) ? "s.n_ins_since_vacuum" : "NULL::bigint"
        let lastSeqScan = version.atLeast(16) ? "s.last_seq_scan" : "NULL::timestamptz"
        return """
        SELECT pg_relation_size(c.oid) AS heap_bytes, pg_total_relation_size(c.oid) AS total_bytes, pg_indexes_size(c.oid) AS index_bytes,
               CASE WHEN c.reltoastrelid <> 0 THEN pg_total_relation_size(c.reltoastrelid) ELSE 0 END AS toast_bytes,
               c.reltuples::float8 AS reltuples, c.relpages::bigint AS relpages,
               CASE WHEN c.relkind IN ('r','m','t') THEN age(c.relfrozenxid) END AS xid_age,
               s.seq_scan, s.seq_tup_read, s.idx_scan, s.idx_tup_fetch, s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_tup_hot_upd,
               s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, \(sinceVacuum) AS n_ins_since_vacuum,
               s.last_vacuum, s.last_autovacuum, s.last_analyze, s.last_autoanalyze, s.vacuum_count, s.autovacuum_count,
               s.analyze_count, s.autoanalyze_count, \(lastSeqScan) AS last_seq_scan,
               io.heap_blks_read, io.heap_blks_hit, current_setting('block_size') AS block_size, c.reloptions::text AS reloptions
        FROM pg_class c LEFT JOIN pg_stat_all_tables s ON s.relid = c.oid LEFT JOIN pg_statio_all_tables io ON io.relid = c.oid
        WHERE c.oid = $1::oid
        """
    }

    /// Subtype of a range type (or, on PostgreSQL 14+, of a multirange: `pg_range.rngmultitypid` is new in 14).
    public static func rangeSubtype(_ version: ServerVersion) -> String {
        let match = version.atLeast(14) ? "rngtypid = $1::oid OR rngmultitypid = $1::oid" : "rngtypid = $1::oid"
        return "SELECT format_type(rngsubtype, NULL) AS base FROM pg_range WHERE \(match)"
    }

    public static func sequence(_ version: ServerVersion) -> String {
        guard version.atLeast(10) else {
            return """
            SELECT 'bigint' AS data_type, NULL::bigint AS start_value, NULL::bigint AS increment, NULL::bigint AS min_value,
                   NULL::bigint AS max_value, NULL::bigint AS cache, false AS cycles, NULL::bigint AS last_value,
                   (SELECT a.attrelid::regclass::text || '.' || quote_ident(a.attname) FROM pg_depend d
                      JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
                    WHERE d.objid = $1::oid AND d.deptype IN ('a','i') AND d.classid = 'pg_class'::regclass LIMIT 1) AS owned_by
            """
        }
        return """
        SELECT format_type(s.seqtypid, NULL) AS data_type, s.seqstart AS start_value, s.seqincrement AS increment,
               s.seqmin AS min_value, s.seqmax AS max_value, s.seqcache AS cache, s.seqcycle AS cycles,
               CASE WHEN has_sequence_privilege(s.seqrelid, 'SELECT,USAGE') THEN pg_sequence_last_value(s.seqrelid) END AS last_value,
               (SELECT a.attrelid::regclass::text || '.' || quote_ident(a.attname) FROM pg_depend d
                  JOIN pg_attribute a ON a.attrelid = d.refobjid AND a.attnum = d.refobjsubid
                WHERE d.objid = s.seqrelid AND d.deptype IN ('a','i') AND d.classid = 'pg_class'::regclass LIMIT 1) AS owned_by
        FROM pg_sequence s WHERE s.seqrelid = $1::oid
        """
    }

    public static let grants = """
        SELECT coalesce(g.rolname, 'PUBLIC') AS grantee, a.privilege_type, a.is_grantable, gr.rolname AS grantor
        FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
        LEFT JOIN pg_roles g ON g.oid = a.grantee LEFT JOIN pg_roles gr ON gr.oid = a.grantor
        WHERE c.oid = $1::oid ORDER BY 1, 2
        """
}

extension PostgresClient {
    public func columns(of relation: RelationSummary, database: String? = nil) async throws -> [ColumnInfo] {
        try await records(InsightSQL.columns(serverInfo.version), [.text(String(relation.oid))], database: database).compactMap(InsightParser.column)
    }

    public func constraints(of relation: RelationSummary, database: String? = nil) async throws -> [ConstraintInfo] {
        try await records(InsightSQL.constraints, [.text(String(relation.oid))], database: database).compactMap(InsightParser.constraint)
    }

    /// Indexes with usage, sizes and (for B-trees) a bloat estimate.
    public func indexes(of relation: RelationSummary, columns: [ColumnInfo]? = nil, database: String? = nil) async throws -> [IndexInfo] {
        let rows = try await records(InsightSQL.indexes(serverInfo.version), [.text(String(relation.oid))], database: database)
        let blockSize = 8192
        let columnInfo: [ColumnInfo]
        if let columns { columnInfo = columns } else { columnInfo = try await self.columns(of: relation, database: database) }
        return rows.compactMap(InsightParser.index).map { index in
            var index = index
            index.bloat = BloatEstimator.btreeIndex(index, columns: columnInfo, blockSize: blockSize)
            return index
        }
    }

    public func triggers(of relation: RelationSummary, database: String? = nil) async throws -> [TriggerInfo] {
        try await records(InsightSQL.triggers, [.text(String(relation.oid))], database: database).compactMap { row in
            guard let name = row.raw("tgname"), let definition = row.string("definition") else { return nil }
            return TriggerInfo(name: name, definition: definition, enabledState: row.text("enabled") ?? "O", function: row.text("function"))
        }
    }

    public func partitioning(of relation: RelationSummary, database: String? = nil) async throws -> PartitioningInfo {
        let version = serverInfo.version
        let oid = BindValue.text(String(relation.oid))
        async let headRows = records(InsightSQL.partitioning(version), [oid], database: database)
        async let childRows = records(InsightSQL.children(version), [oid], database: database)
        let head = try await headRows.first
        let children = try await childRows.compactMap(InsightParser.partition)
        return PartitioningInfo(partitionKey: head?.text("partition_key"), parent: head?.text("parent"), children: children)
    }

    /// Size, activity and vacuum facts plus a heap bloat estimate.
    public func statistics(of relation: RelationSummary, columns: [ColumnInfo]? = nil, database: String? = nil) async throws -> TableStatistics {
        let row = try await records(InsightSQL.statistics(serverInfo.version), [.text(String(relation.oid))], database: database).first
        guard let row else { throw PostgresError(.server, "\(relation.qualifiedName) no longer exists") }
        var statistics = InsightParser.statistics(row)
        if relation.kind.hasStorage {
            let columnInfo: [ColumnInfo]
            if let columns { columnInfo = columns } else { columnInfo = try await self.columns(of: relation, database: database) }
            statistics.bloat = BloatEstimator.table(pages: statistics.pages, tuples: statistics.estimatedRows.map(Double.init),
                                                    columns: columnInfo, blockSize: statistics.blockSize, fillFactor: statistics.fillFactor)
        }
        return statistics
    }

    public func sequenceInfo(_ relation: RelationSummary, database: String? = nil) async throws -> SequenceInfo {
        let version = serverInfo.version
        guard var row = try await records(InsightSQL.sequence(version), [.text(String(relation.oid))], database: database).first else {
            throw PostgresError(.server, "\(relation.qualifiedName) is not a sequence")
        }
        if !version.atLeast(10) {
            // 9.6 keeps the parameters in the sequence relation itself.
            if let details = try? await records("""
                SELECT last_value, start_value, increment_by, min_value, max_value, cache_value, is_cycled, is_called FROM \(relation.qualifiedName)
                """, database: database).first {
                row = Record(["data_type": "bigint", "start_value": details.raw("start_value"), "increment": details.raw("increment_by"),
                              "min_value": details.raw("min_value"), "max_value": details.raw("max_value"), "cache": details.raw("cache_value"),
                              "cycles": details.raw("is_cycled"),
                              "last_value": details.bool("is_called") == true ? details.raw("last_value") : nil,
                              "owned_by": row.raw("owned_by")])
            }
        }
        return InsightParser.sequence(row)
    }

    public func viewDefinition(_ relation: RelationSummary, database: String? = nil) async throws -> String {
        try await records("SELECT pg_get_viewdef($1::oid, true) AS definition", [.text(String(relation.oid))], database: database)
            .first?.string("definition") ?? ""
    }

    public func materializedViewInfo(_ relation: RelationSummary, database: String? = nil) async throws -> MaterializedViewInfo {
        let row = try await records("""
            SELECT m.ispopulated, pg_get_viewdef(c.oid, true) AS definition,
                   EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisunique AND i.indisvalid AND i.indpred IS NULL
                           AND NOT (0 = ANY (i.indkey::int2[]))) AS has_unique
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_matviews m ON m.schemaname = n.nspname AND m.matviewname = c.relname
            WHERE c.oid = $1::oid
            """, [.text(String(relation.oid))], database: database).first
        return MaterializedViewInfo(isPopulated: row?.bool("ispopulated") ?? false, hasUniqueIndex: row?.bool("has_unique") ?? false,
                                    definition: row?.string("definition"))
    }

    /// `REFRESH MATERIALIZED VIEW [CONCURRENTLY]` on a dedicated connection (may take long; cancellable).
    public func refreshMaterializedView(_ relation: RelationSummary, concurrently: Bool, database: String? = nil) async throws {
        let connection = try await makeConnection(database: database)
        do {
            _ = try await connection.simpleQuery("REFRESH MATERIALIZED VIEW \(concurrently ? "CONCURRENTLY " : "")\(relation.qualifiedName)")
            await connection.close()
        } catch {
            await connection.close()
            throw error
        }
    }

    /// CREATE statement(s) for a relation.
    public func ddl(for relation: RelationSummary, database: String? = nil) async throws -> String {
        switch relation.kind {
        case .view, .materializedView:
            let definition = try await viewDefinition(relation, database: database)
            let indexes = relation.kind == .materializedView ? try await self.indexes(of: relation, columns: [], database: database) : []
            return DDLBuilder.view(relation, definition: definition, indexes: indexes)
        case .sequence:
            return DDLBuilder.sequence(relation, info: try await sequenceInfo(relation, database: database))
        case .table, .partitionedTable, .foreignTable:
            let columns = try await columns(of: relation, database: database)
            async let constraints = constraints(of: relation, database: database)
            async let indexes = indexes(of: relation, columns: columns, database: database)
            async let triggers = triggers(of: relation, database: database)
            async let partitioning = partitioning(of: relation, database: database)
            let options = relation.kind == .table ? (try? await statistics(of: relation, columns: columns, database: database).options) ?? [] : []
            return DDLBuilder.table(relation, columns: columns, constraints: try await constraints, indexes: try await indexes,
                                    triggers: try await triggers, partitioning: try await partitioning, options: options)
        }
    }

    public func grants(of relation: RelationSummary, database: String? = nil) async throws -> [GrantInfo] {
        try await records(InsightSQL.grants, [.text(String(relation.oid))], database: database).compactMap { row in
            guard let grantee = row.text("grantee"), let privilege = row.text("privilege_type") else { return nil }
            return GrantInfo(grantee: grantee, privilege: privilege, isGrantable: row.bool("is_grantable") ?? false, grantor: row.text("grantor"))
        }
    }

    /// First rows of a relation for the data preview.
    public func preview(_ relation: RelationSummary, limit: Int = 200, database: String? = nil) async throws -> QueryResult {
        let bounded = min(max(1, limit), 10_000)
        let result = try await query("SELECT * FROM \(relation.qualifiedName) LIMIT \(bounded)", database: database,
                                     limits: RowLimits(maxRows: bounded, maxBytes: 64 * 1024 * 1024))
        return try await resolvingTypeNames(result, database: database)
    }

    public func functionDetail(_ routine: RoutineSummary, database: String? = nil) async throws -> FunctionDetail {
        let row = try await records("""
            SELECT pg_get_userbyid(p.proowner) AS owner, p.procost, p.prorows, p.proisstrict, p.proparallel::text AS parallel,
                   CASE WHEN \(serverInfo.version.atLeast(11) ? "p.prokind <> 'a'" : "NOT p.proisagg") THEN pg_get_functiondef(p.oid) END AS definition
            FROM pg_proc p WHERE p.oid = $1::oid
            """, [.text(String(routine.oid))], database: database).first
        return FunctionDetail(summary: routine, definition: row?.string("definition"), owner: row?.text("owner"), cost: row?.double("procost"),
                              estimatedRows: row?.double("prorows"), isStrict: row?.bool("proisstrict") ?? false, parallel: row?.text("parallel"))
    }

    public func typeDetail(_ type: TypeSummary, database: String? = nil) async throws -> TypeDetail {
        let oid = BindValue.text(String(type.oid))
        switch type.kind {
        case .enumeration:
            let labels = try await records("SELECT enumlabel FROM pg_enum WHERE enumtypid = $1::oid ORDER BY enumsortorder", [oid], database: database)
                .compactMap { $0.raw("enumlabel") }
            return TypeDetail(summary: type, enumLabels: labels)
        case .composite:
            let attributes = try await records("""
                SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type FROM pg_type t JOIN pg_attribute a ON a.attrelid = t.typrelid
                WHERE t.oid = $1::oid AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum
                """, [oid], database: database).compactMap { row in
                row.raw("attname").map { AttributePair(name: $0, type: row.text("type") ?? "") }
            }
            return TypeDetail(summary: type, attributes: attributes)
        case .domain:
            let head = try await records("""
                SELECT format_type(t.typbasetype, t.typtypmod) AS base, t.typnotnull, t.typdefault FROM pg_type t WHERE t.oid = $1::oid
                """, [oid], database: database).first
            let constraints = try await records("SELECT pg_get_constraintdef(oid, true) AS definition FROM pg_constraint WHERE contypid = $1::oid",
                                                [oid], database: database).compactMap { $0.string("definition") }
            return TypeDetail(summary: type, baseType: head?.text("base"), constraints: constraints, defaultExpression: head?.text("typdefault"),
                              isNotNull: head?.bool("typnotnull") ?? false)
        case .range, .multirange:
            let base = try await records(InsightSQL.rangeSubtype(serverInfo.version), [oid], database: database).first?.text("base")
            return TypeDetail(summary: type, baseType: base)
        case .base:
            return TypeDetail(summary: type)
        }
    }

    /// TimescaleDB facts of a hypertable (TimescaleDB 2.x views).
    public func hypertableInfo(_ relation: RelationSummary, database: String? = nil) async throws -> HypertableInfo {
        let parameters: [BindValue] = [.text(relation.schema), .text(relation.name)]
        let head = try await records("""
            SELECT h.num_chunks, h.compression_enabled,
                   (SELECT count(*) FROM timescaledb_information.chunks c WHERE c.hypertable_schema = $1 AND c.hypertable_name = $2 AND c.is_compressed) AS compressed,
                   (SELECT string_agg(d.column_name || ' (' || coalesce(d.time_interval::text, d.num_partitions::text || ' partitions') || ')', ', ')
                      FROM timescaledb_information.dimensions d WHERE d.hypertable_schema = $1 AND d.hypertable_name = $2) AS dimensions,
                   hypertable_size(format('%I.%I', $1, $2)::regclass) AS total_bytes
            FROM timescaledb_information.hypertables h WHERE h.hypertable_schema = $1 AND h.hypertable_name = $2
            """, parameters, database: database).first
        return HypertableInfo(chunkCount: Int(clamping: head?.int("num_chunks") ?? 0), compressionEnabled: head?.bool("compression_enabled") ?? false,
                              compressedChunks: head?.int("compressed").map { Int(clamping: $0) },
                              dimensions: head?.text("dimensions").map { [$0] } ?? [], totalBytes: head?.int("total_bytes"))
    }

    /// PostGIS geometry and geography columns of a relation.
    public func spatialColumns(_ relation: RelationSummary, database: String? = nil) async throws -> [SpatialColumn] {
        try await records("""
            SELECT f_geometry_column AS col, type, srid, coord_dimension FROM geometry_columns WHERE f_table_schema = $1 AND f_table_name = $2
            UNION ALL
            SELECT f_geography_column, 'geography(' || type || ')', srid, coord_dimension FROM geography_columns WHERE f_table_schema = $1 AND f_table_name = $2
            """, [.text(relation.schema), .text(relation.name)], database: database).compactMap { row in
            row.raw("col").map {
                SpatialColumn(column: $0, type: row.text("type") ?? "", srid: row.int("srid").map { Int(clamping: $0) },
                              dimensions: row.int("coord_dimension").map { Int(clamping: $0) })
            }
        }
    }
}

/// Record → model conversions for insights (pure; unit-tested).
public enum InsightParser {
    public static func column(_ row: Record) -> ColumnInfo? {
        guard let number = row.int("attnum"), let name = row.raw("attname") else { return nil }
        let generated = row.text("generated")
        let defaultExpression = row.text("default_expr")
        return ColumnInfo(number: Int(clamping: number), name: name, type: row.text("type") ?? "", isNullable: !(row.bool("attnotnull") ?? false),
                          defaultExpression: generated == nil ? defaultExpression : nil,
                          identity: row.text("identity"), generatedExpression: generated != nil ? defaultExpression : nil,
                          collation: row.text("collation"), comment: row.string("comment"), nullFraction: row.double("null_frac"),
                          distinctValues: row.double("n_distinct"), averageWidth: row.int("avg_width").map { Int(clamping: $0) },
                          isLocal: row.bool("attislocal") ?? true)
    }

    public static func constraint(_ row: Record) -> ConstraintInfo? {
        guard let name = row.raw("conname"), let kind = row.text("contype").flatMap(ConstraintKind.init(rawValue:)) else { return nil }
        return ConstraintInfo(name: name, kind: kind, definition: row.string("definition") ?? "", isDeferrable: row.bool("condeferrable") ?? false,
                              isValidated: row.bool("convalidated") ?? true, referencedTable: row.text("referenced"),
                              isLocal: row.bool("conislocal") ?? true)
    }

    public static func index(_ row: Record) -> IndexInfo? {
        guard let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let name = row.raw("name") else { return nil }
        let keys = (row.text("indkey") ?? "").split(separator: " ").compactMap { Int($0) }
        return IndexInfo(oid: oid, name: name, definition: row.string("definition") ?? "", method: row.text("method") ?? "",
                         isUnique: row.bool("indisunique") ?? false, isPrimary: row.bool("indisprimary") ?? false,
                         isValid: row.bool("indisvalid") ?? true, constraintName: row.text("constraint_name"), sizeBytes: row.int("size_bytes"),
                         scans: row.int("idx_scan"), tuplesRead: row.int("idx_tup_read"), tuplesFetched: row.int("idx_tup_fetch"),
                         columnNumbers: keys, estimatedTuples: row.double("reltuples"), pages: row.int("relpages"), lastScan: row.date("last_scan"),
                         fillFactor: row.int("fillfactor").map { Int(clamping: $0) })
    }

    public static func partition(_ row: Record) -> PartitionInfo? {
        guard let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let schema = row.text("schema"), let name = row.raw("name") else { return nil }
        let tuples = row.double("reltuples")
        return PartitionInfo(oid: oid, schema: schema, name: name, bound: row.text("bound"),
                             kind: row.text("relkind").flatMap(RelationKind.init(rawValue:)), totalBytes: row.int("total_bytes"),
                             estimatedRows: tuples.flatMap { $0 < 0 ? nil : Int64(exactly: $0.rounded()) })
    }

    public static func statistics(_ row: Record) -> TableStatistics {
        var statistics = TableStatistics(blockSize: Int(clamping: row.int("block_size") ?? 8192))
        statistics.heapBytes = row.int("heap_bytes")
        statistics.toastBytes = row.int("toast_bytes")
        statistics.indexBytes = row.int("index_bytes")
        statistics.totalBytes = row.int("total_bytes")
        if let tuples = row.double("reltuples"), tuples >= 0 { statistics.estimatedRows = Int64(exactly: tuples.rounded()) }
        statistics.pages = row.int("relpages")
        statistics.transactionIDAge = row.int("xid_age")
        statistics.sequentialScans = row.int("seq_scan")
        statistics.sequentialTuplesRead = row.int("seq_tup_read")
        statistics.indexScans = row.int("idx_scan")
        statistics.indexTuplesFetched = row.int("idx_tup_fetch")
        statistics.inserted = row.int("n_tup_ins")
        statistics.updated = row.int("n_tup_upd")
        statistics.deleted = row.int("n_tup_del")
        statistics.hotUpdated = row.int("n_tup_hot_upd")
        statistics.liveTuples = row.int("n_live_tup")
        statistics.deadTuples = row.int("n_dead_tup")
        statistics.modifiedSinceAnalyze = row.int("n_mod_since_analyze")
        statistics.insertedSinceVacuum = row.int("n_ins_since_vacuum")
        statistics.lastVacuum = row.date("last_vacuum")
        statistics.lastAutovacuum = row.date("last_autovacuum")
        statistics.lastAnalyze = row.date("last_analyze")
        statistics.lastAutoanalyze = row.date("last_autoanalyze")
        statistics.vacuumCount = row.int("vacuum_count")
        statistics.autovacuumCount = row.int("autovacuum_count")
        statistics.analyzeCount = row.int("analyze_count")
        statistics.autoanalyzeCount = row.int("autoanalyze_count")
        statistics.lastSequentialScan = row.date("last_seq_scan")
        statistics.heapBlocksRead = row.int("heap_blks_read")
        statistics.heapBlocksHit = row.int("heap_blks_hit")
        statistics.options = row.array("reloptions")
        statistics.fillFactor = statistics.options.first { $0.hasPrefix("fillfactor=") }
            .flatMap { Int($0.dropFirst("fillfactor=".count)) }
        return statistics
    }

    public static func sequence(_ row: Record) -> SequenceInfo {
        SequenceInfo(dataType: row.text("data_type") ?? "bigint", startValue: row.int("start_value"), increment: row.int("increment"),
                     minValue: row.int("min_value"), maxValue: row.int("max_value"), cache: row.int("cache"),
                     cycles: row.bool("cycles") ?? false, lastValue: row.int("last_value"), ownedBy: row.text("owned_by"))
    }
}
