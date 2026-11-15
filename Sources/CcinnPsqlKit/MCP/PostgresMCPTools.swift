import Foundation
import PostgresKit
import PostgresWire

/// Opens (once) and caches a client per profile for the lifetime of the MCP process.
public actor MCPClientRegistry {
    public typealias Opener = @Sendable (ConnectionProfile) async throws -> PostgresClient

    private let opener: Opener
    private var clients: [UUID: PostgresClient] = [:]
    private var opening: [UUID: Task<PostgresClient, any Error>] = [:]

    public init(opener: @escaping Opener) {
        self.opener = opener
    }

    public func client(for profile: ConnectionProfile) async throws -> PostgresClient {
        if let client = clients[profile.id] { return client }
        if let pending = opening[profile.id] { return try await pending.value }
        let opener = opener
        let task = Task { try await opener(profile) }
        opening[profile.id] = task
        do {
            let client = try await task.value
            opening[profile.id] = nil
            clients[profile.id] = client
            return client
        } catch {
            opening[profile.id] = nil
            throw error
        }
    }

    public func closeAll() async {
        let open = Array(clients.values)
        clients.removeAll()
        for client in open { await client.close() }
    }
}

/// The PostgreSQL tool set of the MCP server (shared ccinn MCP design, section 6; design D14).
public struct PostgresMCPTools: MCPToolProvider {
    public let resolver: MCPProfileResolver
    public let registry: MCPClientRegistry
    public let audit: MCPAuditLog?

    public static let defaultRowLimit = 200
    public static let maxRowLimit = 1_000
    public static let defaultTimeout = 30.0
    public static let maxTimeout = 120.0

    public init(resolver: MCPProfileResolver, registry: MCPClientRegistry, audit: MCPAuditLog?) {
        self.resolver = resolver
        self.registry = registry
        self.audit = audit
    }

    // MARK: Definitions

    public func tools() async -> [MCPTool] {
        var tools: [MCPTool] = [
            MCPTool(name: "list_connections", title: "List connections",
                    description: "Lists the saved PostgreSQL connections the user enabled for AI access (no secrets).",
                    inputSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false], readOnly: true),
            MCPTool(name: "server_info", title: "Server info",
                    description: "PostgreSQL version, current user/database, superuser flag, standby (in recovery) status, TLS, connection pooler (PgBouncer/Pgpool and pooling mode), max_connections and installed extensions (pg_stat_statements, TimescaleDB, Citus, PostGIS, …).",
                    inputSchema: Self.schema([:]), readOnly: true),
            MCPTool(name: "list_databases", title: "List databases",
                    description: "Databases of the server with size, owner, encoding and transaction-ID age.",
                    inputSchema: Self.schema([:]), readOnly: true),
            MCPTool(name: "list_schemas", title: "List schemas",
                    description: "Schemas of a database (system schemas excluded unless include_system is true).",
                    inputSchema: Self.schema(["database": Self.databaseProperty,
                                              "include_system": ["type": "boolean", "description": "Include pg_catalog, information_schema and extension-internal schemas."]]),
                    readOnly: true),
            MCPTool(name: "list_tables", title: "List tables and views",
                    description: "Tables, partitioned tables (with their partitions), views, materialized views, foreign tables and sequences of a schema, with estimated rows, total size, partition parent/bounds, TimescaleDB hypertable and Citus distribution markers.",
                    inputSchema: Self.schema(["schema": Self.schemaProperty, "database": Self.databaseProperty,
                                              "name_filter": ["type": "string", "description": "Case-insensitive substring to filter names."]],
                                             required: ["schema"]), readOnly: true),
            MCPTool(name: "describe_table", title: "Describe table",
                    description: "Columns (type, nullability, default, identity/generated, comment), constraints, indexes (definition, size, scans, unused flag), triggers, partitioning (key, parent, partitions) and optionally the reconstructed CREATE statement of a table, view or materialized view.",
                    inputSchema: Self.schema(["schema": Self.schemaProperty, "table": Self.tableProperty, "database": Self.databaseProperty,
                                              "include_ddl": ["type": "boolean", "description": "Include the CREATE statement (default true)."]],
                                             required: ["schema", "table"]), readOnly: true),
            MCPTool(name: "get_table_stats", title: "Table statistics",
                    description: "Heap/TOAST/index sizes, estimated rows, sequential vs index scans, live/dead tuples, last (auto)vacuum and (auto)analyze, transaction-ID age, estimated table and index bloat, and unused indexes of a table.",
                    inputSchema: Self.schema(["schema": Self.schemaProperty, "table": Self.tableProperty, "database": Self.databaseProperty],
                                             required: ["schema", "table"]), readOnly: true, idempotent: false),
            MCPTool(name: "get_activity", title: "Activity and blocking",
                    description: "Sessions from pg_stat_activity (state, wait event, query duration, client, query) and the blocking tree built from pg_blocking_pids. Idle sessions are omitted unless include_idle is true.",
                    inputSchema: Self.schema(["include_idle": ["type": "boolean", "description": "Include idle sessions (default false)."],
                                              "limit": ["type": "integer", "minimum": 1, "maximum": 500, "description": "Maximum sessions (default 100)."]]),
                    readOnly: true, idempotent: false),
            MCPTool(name: "get_replication", title: "Replication",
                    description: "Standbys connected to this server with write/flush/replay lag, replication slots with retained WAL and status, and standby facts when this server is in recovery.",
                    inputSchema: Self.schema([:]), readOnly: true, idempotent: false),
            MCPTool(name: "get_top_statements", title: "Top statements",
                    description: "Most expensive statements from pg_stat_statements (calls, total/mean/max time, rows, cache hit ratio, temp blocks), if the extension is installed.",
                    inputSchema: Self.schema(["database": Self.databaseProperty,
                                              "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Statements to return (default 20)."]]),
                    readOnly: true, idempotent: false),
            MCPTool(name: "run_query", title: "Run read-only SQL",
                    description: "Runs one read-only statement (SELECT, WITH … SELECT, VALUES, TABLE, SHOW, EXPLAIN) inside a READ ONLY transaction with a statement timeout and returns columns and rows. A LIMIT is added to queries without one; results are capped at `limit` rows and about 256 KB.",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A single read-only SQL statement."],
                                              "database": Self.databaseProperty,
                                              "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(Self.maxRowLimit)), "description": "Maximum rows (default 200)."],
                                              "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout)), "description": "Time limit (default 30)."]],
                                             required: ["sql"]), readOnly: true, idempotent: false),
            MCPTool(name: "explain_query", title: "Explain query",
                    description: "Execution plan of a read-only query with EXPLAIN (FORMAT JSON), optionally ANALYZE and BUFFERS (the query is then executed inside a READ ONLY transaction). Returns a readable plan tree with costs, actual times, self time per node and row-estimate misses, plus the JSON plan.",
                    inputSchema: Self.schema(["sql": ["type": "string", "description": "A SELECT, WITH, VALUES or TABLE query."],
                                              "database": Self.databaseProperty,
                                              "analyze": ["type": "boolean", "description": "Execute the query and report actual times and rows (default false)."],
                                              "buffers": ["type": "boolean", "description": "Report buffer usage (default true when analyze is set)."],
                                              "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout))]],
                                             required: ["sql"]), readOnly: true, idempotent: false),
        ]
        if resolver.anyWritable {
            tools.append(MCPTool(name: "execute_statement", title: "Execute SQL (writes allowed)",
                                 description: "Runs one SQL statement that may change data or schema (INSERT, UPDATE, DELETE, CREATE, ALTER, REFRESH MATERIALIZED VIEW, VACUUM, …). Only available on connections with read-write AI access. Prefer run_query for reads.",
                                 inputSchema: Self.schema(["sql": ["type": "string", "description": "A single SQL statement."],
                                                           "database": Self.databaseProperty,
                                                           "timeout_seconds": ["type": "number", "minimum": 1, "maximum": .int(Int64(Self.maxTimeout))]],
                                                          required: ["sql"]), readOnly: false, destructive: true, idempotent: false))
        }
        return tools
    }

    static let connectionProperty: JSONValue = ["type": "string", "description": "Saved connection name or id (see list_connections). Optional when only one connection is enabled or a default was configured."]
    static let databaseProperty: JSONValue = ["type": "string", "description": "Database name (default: the connection's database)."]
    static let schemaProperty: JSONValue = ["type": "string", "description": "Schema name, e.g. public."]
    static let tableProperty: JSONValue = ["type": "string", "description": "Table, view or materialized view name."]

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var all = properties
        all["connection"] = connectionProperty
        return ["type": "object", "properties": .object(all), "required": .array(required.map(JSONValue.string)), "additionalProperties": false]
    }

    // MARK: Calls

    /// Collects audit details while a tool runs.
    final class CallContext: @unchecked Sendable {
        var connection: String?
        var statement: String?
        var rows: Int?
    }

    public func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        let clock = ContinuousClock()
        let started = clock.now
        let context = CallContext()
        let result: MCPToolResult
        do {
            result = .success(try await dispatch(name, MCPArguments(arguments), context))
        } catch let error as MCPToolError {
            result = .failure(error.message)
        } catch let error as PostgresError {
            var message = error.summary
            if let detail = error.detail { message += "\nDetail: \(detail)" }
            if let hint = error.hint { message += "\nHint: \(hint)" }
            if error.sqlState == "25006" { message += "\nThe statement tried to write; read-only tools run inside a READ ONLY transaction." }
            result = .failure(message)
        } catch {
            result = .failure(error.localizedDescription)
        }
        let elapsed = clock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        await audit?.record(tool: name, connection: context.connection, statement: context.statement, durationMilliseconds: milliseconds,
                            rows: context.rows, error: result.isError ? result.payload.stringValue : nil)
        return result
    }

    private func dispatch(_ name: String, _ args: MCPArguments, _ context: CallContext) async throws -> JSONValue {
        if name == "list_connections" { return listConnections() }
        let known = ["server_info", "list_databases", "list_schemas", "list_tables", "describe_table", "get_table_stats", "get_activity",
                     "get_replication", "get_top_statements", "run_query", "explain_query", "execute_statement"]
        guard known.contains(name) else { throw MCPToolError("Unknown tool “\(name)”.") }
        let resolved = try resolver.resolve(args.string("connection"))
        context.connection = resolved.profile.displayName
        if name == "execute_statement", resolved.access != .readWrite {
            throw MCPToolError("Connection “\(resolved.profile.displayName)” only allows read-only AI access; use run_query, or change its AI access to Read & write in CcinnPsql.")
        }
        // Reject writes before opening any connection.
        if name == "run_query", let sql = args.string("sql"), let reason = ReadOnlySQLGuard.check(sql) {
            let hint = resolved.access == .readWrite ? " Use execute_statement for statements that change data." : ""
            throw MCPToolError(reason + hint)
        }
        let client = try await registry.client(for: resolved.profile)
        if client.serverInfo.isPgBouncerConsole, !["server_info", "run_query"].contains(name) {
            throw MCPToolError("This connection is the PgBouncer admin console; only server_info and run_query with SHOW commands (SHOW POOLS, SHOW STATS, …) work here.")
        }
        switch name {
        case "server_info": return serverInfo(client)
        case "list_databases": return try await listDatabases(client)
        case "list_schemas": return try await listSchemas(client, args)
        case "list_tables": return try await listTables(client, args)
        case "describe_table": return try await describeTable(client, args)
        case "get_table_stats": return try await tableStats(client, args)
        case "get_activity": return try await activity(client, args)
        case "get_replication": return try await replication(client)
        case "get_top_statements": return try await topStatements(client, args)
        case "run_query": return try await runQuery(client, args, context, access: resolved.access)
        case "explain_query": return try await explain(client, args, context)
        default: return try await execute(client, args, context)
        }
    }

    private func listConnections() -> JSONValue {
        ["connections": .array(resolver.enabledProfiles.map { profile in
            [
                "name": .string(profile.displayName),
                "id": .string(profile.id.uuidString),
                "endpoint": .string(profile.endpoint.description),
                "user": .string(profile.username),
                "database": .string(profile.effectiveDatabase),
                "ssl_mode": .string(profile.sslMode.rawValue),
                "ssh_tunnel": .bool(profile.ssh != nil),
                "pooling_mode": .string(profile.poolingMode.rawValue),
                "access": .string(resolver.access(of: profile) == .readWrite ? "read_write" : "read_only"),
            ]
        })]
    }

    // MARK: Metadata tools

    private func serverInfo(_ client: PostgresClient) -> JSONValue {
        let info = client.serverInfo
        return [
            "product": .string(info.productSummary), "version": .string(info.version.description), "version_string": .string(info.versionString),
            "current_user": .string(info.currentUser), "current_database": .string(info.currentDatabase), "superuser": .bool(info.isSuperuser),
            "in_recovery": .bool(info.isInRecovery), "tls": .bool(info.tlsDescription != nil), "tls_version": JSONValue(info.tlsDescription),
            "pooler": .string(info.pooler.displayName),
            "pooling_mode": .string(info.poolingMode.rawValue), "pooling_detail": .string(info.poolingDetail),
            "max_connections": JSONValue(info.maxConnections),
            "extensions": .array(info.extensions.map { ["name": .string($0.name), "version": .string($0.version), "schema": .string($0.schema)] }),
        ]
    }

    private func listDatabases(_ client: PostgresClient) async throws -> JSONValue {
        ["databases": .array(try await client.databases().map { database in
            [
                "name": .string(database.name), "owner": JSONValue(database.owner), "encoding": JSONValue(database.encoding),
                "size_bytes": JSONValue(database.sizeBytes), "is_template": .bool(database.isTemplate),
                "allows_connections": .bool(database.allowsConnections), "xid_age": JSONValue(database.transactionIDAge),
                "comment": JSONValue(database.comment),
            ]
        })]
    }

    private func listSchemas(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let includeSystem = args.bool("include_system") ?? false
        let schemas = try await client.schemas(database: args.string("database")).filter { includeSystem || !$0.isSystem }
        return ["database": .string(args.string("database") ?? client.defaultDatabase),
                "schemas": .array(schemas.map { ["name": .string($0.name), "owner": JSONValue($0.owner), "comment": JSONValue($0.comment)] })]
    }

    private func listTables(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let schema = try args.required("schema")
        let contents = try await client.schemaContents(schema, database: args.string("database"))
        var relations = contents.relations
        if let filter = args.string("name_filter") {
            relations = relations.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        }
        let byOID = Dictionary(contents.relations.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        let cap = 1_000
        return [
            "schema": .string(schema), "database": .string(args.string("database") ?? client.defaultDatabase),
            "objects": .array(relations.prefix(cap).map { Self.encode(relation: $0, parent: $0.parentOID.flatMap { byOID[$0] }) }),
            "count": .int(Int64(relations.count)), "truncated": .bool(relations.count > cap),
            "routines": .int(Int64(contents.routines.count)), "types": .int(Int64(contents.types.count)),
        ]
    }

    private func findRelation(_ client: PostgresClient, _ args: MCPArguments) async throws -> RelationSummary {
        let schema = try args.required("schema")
        let name = try args.required("table")
        let contents = try await client.schemaContents(schema, database: args.string("database"))
        if let exact = contents.relations.first(where: { $0.name == name })
            ?? contents.relations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        let similar = contents.relations.filter { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
            .prefix(10).map(\.name)
        throw MCPToolError("No table or view named “\(name)” in schema \(schema).\(similar.isEmpty ? "" : " Similar: \(similar.joined(separator: ", ")).")")
    }

    private func describeTable(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let relation = try await findRelation(client, args)
        let database = args.string("database")
        var result = Self.encode(relation: relation, parent: nil).objectValue ?? [:]
        if relation.kind != .sequence {
            let columns = try await client.columns(of: relation, database: database)
            result["columns"] = .array(columns.map { column in
                .object([
                    "name": .string(column.name), "type": .string(column.type), "nullable": .bool(column.isNullable),
                    "default": JSONValue(column.defaultExpression), "identity": JSONValue(column.identityDescription),
                    "generated": JSONValue(column.generatedExpression), "comment": JSONValue(column.comment),
                ].filter { $0.value != .null })
            })
            if relation.kind.isTableLike || relation.kind == .materializedView {
                let constraints = try await client.constraints(of: relation, database: database)
                let indexes = try await client.indexes(of: relation, columns: columns, database: database)
                let triggers = try await client.triggers(of: relation, database: database)
                result["constraints"] = .array(constraints.filter { $0.kind != .notNull }.map {
                    ["name": .string($0.name), "type": .string($0.kind.displayName), "definition": .string($0.definition)]
                })
                result["indexes"] = .array(indexes.map(Self.encode(index:)))
                result["triggers"] = .array(triggers.map { ["name": .string($0.name), "definition": .string($0.definition), "enabled": .bool($0.isEnabled)] })
                if relation.kind == .partitionedTable || relation.isPartition || relation.hasChildren {
                    let partitioning = try await client.partitioning(of: relation, database: database)
                    result["partition_key"] = JSONValue(partitioning.partitionKey)
                    result["parent"] = JSONValue(partitioning.parent)
                    result["partitions"] = .array(partitioning.children.prefix(500).map {
                        ["name": .string("\($0.schema).\($0.name)"), "bound": JSONValue($0.bound), "total_bytes": JSONValue($0.totalBytes),
                         "estimated_rows": JSONValue($0.estimatedRows)]
                    })
                }
            }
        }
        if args.bool("include_ddl") ?? true {
            result["ddl"] = .string(try await client.ddl(for: relation, database: database))
        }
        return .object(result)
    }

    private func tableStats(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let relation = try await findRelation(client, args)
        guard relation.kind.hasStorage || relation.kind == .partitionedTable else {
            throw MCPToolError("\(relation.qualifiedName) is a \(relation.kind.displayName.lowercased()); statistics exist for tables and materialized views.")
        }
        let database = args.string("database")
        let columns = try await client.columns(of: relation, database: database)
        let stats = try await client.statistics(of: relation, columns: columns, database: database)
        let indexes = try await client.indexes(of: relation, columns: columns, database: database)
        func date(_ value: Date?) -> JSONValue { value.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null }
        let result: [String: JSONValue] = [
            "table": .string(relation.qualifiedName), "heap_bytes": JSONValue(stats.heapBytes), "toast_bytes": JSONValue(stats.toastBytes),
            "index_bytes": JSONValue(stats.indexBytes), "total_bytes": JSONValue(stats.totalBytes), "estimated_rows": JSONValue(stats.estimatedRows),
            "seq_scans": JSONValue(stats.sequentialScans), "seq_tuples_read": JSONValue(stats.sequentialTuplesRead),
            "index_scans": JSONValue(stats.indexScans), "live_tuples": JSONValue(stats.liveTuples), "dead_tuples": JSONValue(stats.deadTuples),
            "dead_tuple_ratio": JSONValue(stats.deadTupleRatio), "modified_since_analyze": JSONValue(stats.modifiedSinceAnalyze),
            "last_vacuum": date(stats.lastVacuum), "last_autovacuum": date(stats.lastAutovacuum), "last_analyze": date(stats.lastAnalyze),
            "last_autoanalyze": date(stats.lastAutoanalyze), "xid_age": JSONValue(stats.transactionIDAge),
            "cache_hit_ratio": JSONValue(stats.cacheHitRatio),
            "estimated_bloat_bytes": JSONValue(stats.bloat?.wastedBytes), "estimated_bloat_ratio": JSONValue(stats.bloat?.ratio),
            "indexes": .array(indexes.map(Self.encode(index:))),
            "unused_indexes": .array(indexes.filter(\.isUnused).map { .string($0.name) }),
            "note": "Bloat figures are estimates from planner statistics; run ANALYZE first for accurate numbers.",
        ]
        return .object(result.filter { $0.value != .null })
    }

    private func activity(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let snapshot = try await client.activity()
        let includeIdle = args.bool("include_idle") ?? false
        let limit = args.int("limit", default: 100, range: 1...500)
        let sessions = snapshot.sessions.filter { !$0.isCurrentSession && (includeIdle || !$0.isIdle) }
        let tree = BlockingTree.build(snapshot.sessions)
        func encode(_ node: BlockingNode) -> JSONValue {
            ["pid": .int(Int64(node.session.pid)), "user": JSONValue(node.session.user), "state": JSONValue(node.session.state),
             "wait": JSONValue(node.session.waitDescription), "query": JSONValue(node.session.query.map { String($0.prefix(500)) }),
             "blocked": .array(node.waiters.map(encode))]
        }
        return [
            "sessions": .array(sessions.prefix(limit).map { session in
                .object([
                    "pid": .int(Int64(session.pid)), "user": JSONValue(session.user), "database": JSONValue(session.database),
                    "application": JSONValue(session.applicationName), "client": JSONValue(session.clientAddress),
                    "backend_type": JSONValue(session.backendType), "state": JSONValue(session.state), "wait": JSONValue(session.waitDescription),
                    "query_seconds": JSONValue(session.querySeconds.map { ($0 * 10).rounded() / 10 }),
                    "transaction_seconds": JSONValue(session.transactionSeconds.map { ($0 * 10).rounded() / 10 }),
                    "blocked_by": .array(session.blockedBy.map { .int(Int64($0)) }),
                    "query": JSONValue(session.query.map { String($0.prefix(2_000)) }),
                ].filter { $0.value != .null })
            }),
            "session_count": .int(Int64(sessions.count)), "truncated": .bool(sessions.count > limit),
            "blocking_tree": .array(tree.map(encode)),
        ]
    }

    private func replication(_ client: PostgresClient) async throws -> JSONValue {
        let overview = try await client.replication()
        return [
            "in_recovery": .bool(overview.isInRecovery), "current_lsn": JSONValue(overview.currentLSN),
            "standbys": .array(overview.connections.map { connection in
                ["application": JSONValue(connection.applicationName), "client": JSONValue(connection.clientAddress), "state": JSONValue(connection.state),
                 "sync_state": JSONValue(connection.syncState), "replay_lag_bytes": JSONValue(connection.replayLagBytes),
                 "write_lag_seconds": JSONValue(connection.writeLagSeconds), "flush_lag_seconds": JSONValue(connection.flushLagSeconds),
                 "replay_lag_seconds": JSONValue(connection.replayLagSeconds)]
            }),
            "slots": .array(overview.slots.map { slot in
                ["name": .string(slot.name), "type": .string(slot.slotType), "plugin": JSONValue(slot.plugin), "database": JSONValue(slot.database),
                 "active": .bool(slot.isActive), "retained_wal_bytes": JSONValue(slot.retainedBytes), "wal_status": JSONValue(slot.walStatus),
                 "risk": .bool(slot.isRisky)]
            }),
            "standby": overview.standby.map { standby in
                ["receive_lsn": JSONValue(standby.receiveLSN), "replay_lsn": JSONValue(standby.replayLSN),
                 "replay_delay_seconds": JSONValue(standby.replayDelaySeconds), "replay_paused": JSONValue(standby.isReplayPaused),
                 "upstream": JSONValue(standby.upstream)]
            } ?? .null,
        ]
    }

    private func topStatements(_ client: PostgresClient, _ args: MCPArguments) async throws -> JSONValue {
        let limit = args.int("limit", default: 20, range: 1...200)
        let (availability, statements) = try await client.topStatements(limit: limit, database: args.string("database"))
        switch availability {
        case .available: break
        case .extensionMissing:
            throw MCPToolError("pg_stat_statements is not installed in this database. Add it to shared_preload_libraries, restart, then run CREATE EXTENSION pg_stat_statements.")
        case let .notPreloaded(message), let .failed(message):
            throw MCPToolError("pg_stat_statements is unavailable: \(message)")
        }
        return ["statements": .array(statements.map { statement in
            .object([
                "query": .string(String(statement.query.prefix(4_000))), "calls": .int(statement.calls),
                "total_ms": .double((statement.totalMilliseconds * 100).rounded() / 100),
                "mean_ms": JSONValue(statement.meanMilliseconds.map { ($0 * 100).rounded() / 100 }),
                "max_ms": JSONValue(statement.maxMilliseconds.map { ($0 * 100).rounded() / 100 }), "rows": JSONValue(statement.rows),
                "cache_hit_ratio": JSONValue(statement.cacheHitRatio), "temp_blocks_written": JSONValue(statement.tempBlocksWritten),
                "user": JSONValue(statement.user), "database": JSONValue(statement.database),
            ].filter { $0.value != .null })
        })]
    }

    // MARK: SQL tools

    private func runQuery(_ client: PostgresClient, _ args: MCPArguments, _ context: CallContext, access: MCPAccess) async throws -> JSONValue {
        let sql = try args.required("sql")
        if let reason = ReadOnlySQLGuard.check(sql) {
            let hint = access == .readWrite ? " Use execute_statement for statements that change data." : ""
            throw MCPToolError(reason + hint)
        }
        guard let statement = SQLStatementSplitter.split(sql).first?.text else { throw MCPToolError("The statement is empty.") }
        let limit = args.int("limit", default: Self.defaultRowLimit, range: 1...Self.maxRowLimit)
        var executed = statement
        var limitApplied = false
        if SQLStatementKind.of(statement) == .query {
            let outcome = AutoLimit.apply(to: statement, limit: limit + 1)
            executed = outcome.sql
            limitApplied = outcome.applied
        }
        context.statement = executed
        let started = ContinuousClock.now
        let result = try await Self.readOnly(client, sql: executed, database: args.string("database"), timeout: timeout(args),
                                             limits: RowLimits(maxRows: limit, maxBytes: 64 * 1024 * 1024))
        let elapsed = ContinuousClock.now - started
        var payload = Self.encode(result: result, limitRows: limit)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        payload["statement"] = .string(executed)
        payload["limit_applied"] = .bool(limitApplied)
        payload["database"] = .string(args.string("database") ?? client.defaultDatabase)
        payload["elapsed_ms"] = .int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        if !result.notices.isEmpty { payload["notices"] = .array(result.notices.prefix(20).map { .string("\($0.severity): \($0.message)") }) }
        return .object(payload)
    }

    private func explain(_ client: PostgresClient, _ args: MCPArguments, _ context: CallContext) async throws -> JSONValue {
        let sql = try args.required("sql")
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else { throw MCPToolError("Pass exactly one query.") }
        guard SQLStatementKind.of(statement) == .query else { throw MCPToolError("explain_query explains read-only queries (SELECT, WITH, VALUES, TABLE).") }
        let analyze = args.bool("analyze") ?? false
        let body = ExplainPlan.statement(for: statement, analyze: analyze, buffers: args.bool("buffers") ?? analyze)
        if let reason = ReadOnlySQLGuard.check(body) { throw MCPToolError(reason) }
        context.statement = body
        let result = try await Self.readOnly(client, sql: body, database: args.string("database"), timeout: timeout(args),
                                             limits: RowLimits(maxRows: 10, maxBytes: 32 * 1024 * 1024))
        guard let json = result.lastRowSet?.scalar else { throw MCPToolError("EXPLAIN returned no plan.") }
        let plan = try ExplainPlan.parse(json)
        context.rows = plan.nodes.count
        var payload: [String: JSONValue] = [
            "statement": .string(body), "plan": .string(plan.summary()), "analyzed": .bool(plan.isAnalyzed),
            "planning_ms": JSONValue(plan.planningTime), "execution_ms": JSONValue(plan.executionTime),
            "total_cost": JSONValue(plan.root.totalCost), "node_count": .int(Int64(plan.nodes.count)),
        ]
        if let slowest = plan.slowestNode {
            payload["slowest_node"] = .string("\(slowest.title)\(slowest.subtitle.map { " " + $0 } ?? "") — \(String(format: "%.3f", slowest.exclusiveTime ?? 0)) ms self time")
        }
        let misestimates = plan.nodes.filter(\.isMisestimated)
        if !misestimates.isEmpty {
            payload["row_estimate_misses"] = .array(misestimates.prefix(10).map { node in
                .string("\(node.title)\(node.subtitle.map { " " + $0 } ?? ""): planned \(Int(node.planRows ?? 0)), actual \(Int(node.actualRows ?? 0)) per loop")
            })
        }
        if json.utf8.count <= 128 * 1024, let parsed = try? JSONValue.parse(json) { payload["json"] = parsed }
        return .object(payload.filter { $0.value != .null })
    }

    private func execute(_ client: PostgresClient, _ args: MCPArguments, _ context: CallContext) async throws -> JSONValue {
        let sql = try args.required("sql")
        let statements = SQLStatementSplitter.split(sql)
        guard statements.count == 1, let statement = statements.first?.text else {
            throw MCPToolError("Pass exactly one statement per call.")
        }
        context.statement = statement
        let timeout = timeout(args)
        let database = args.string("database")
        let result: QueryResult = try await client.withConnection(database: database) { connection in
            try await Deadline.run(seconds: timeout, timeoutError: Self.timeoutError(timeout)) {
                if client.serverInfo.keepsSessionState {
                    _ = try await connection.simpleQuery("SET statement_timeout = \(Int(timeout * 1000))")
                }
                do {
                    let result = try await connection.extendedQuery(statement, limits: RowLimits(maxRows: Self.maxRowLimit, maxBytes: 64 * 1024 * 1024))
                    await Self.endCall(on: connection, client: client)
                    return result
                } catch {
                    await Self.endCall(on: connection, client: client)
                    throw error
                }
            }
        }
        var payload = Self.encode(result: result, limitRows: Self.maxRowLimit)
        payload["statement"] = .string(statement)
        context.rows = payload["row_count"]?.intValue.map { Int(clamping: $0) }
        return .object(payload)
    }

    private func timeout(_ args: MCPArguments) -> Double {
        min(max(args.double("timeout_seconds") ?? Self.defaultTimeout, 1), Self.maxTimeout)
    }

    static func timeoutError(_ timeout: Double) -> @Sendable () -> PostgresError {
        { PostgresError(.timeout, "The statement did not finish within \(Int(timeout)) s and was cancelled; narrow the query or raise timeout_seconds (max \(Int(maxTimeout))).") }
    }

    /// Runs one statement through the extended protocol inside `BEGIN READ ONLY … ROLLBACK` with a server-side
    /// statement timeout (design D14). Cancelling the calling task sends a CancelRequest.
    static func readOnly(_ client: PostgresClient, sql: String, database: String?, timeout: Double, limits: RowLimits) async throws -> QueryResult {
        if client.serverInfo.isPgBouncerConsole {
            guard SQLStatementKind.of(sql) == .show else {
                throw MCPToolError("The PgBouncer admin console only accepts SHOW commands (SHOW POOLS, SHOW STATS, SHOW CLIENTS, …).")
            }
            return try await client.simpleQuery(sql, database: database, limits: limits, timeout: timeout)
        }
        return try await client.withConnection(database: database) { connection in
            try await Deadline.run(seconds: timeout, timeoutError: timeoutError(timeout)) {
                do {
                    _ = try await connection.simpleQuery(client.routingPrefix + readOnlyPreamble(timeout: timeout), limits: .metadata)
                    let result = try await connection.extendedQuery(sql, limits: limits)
                    // Same connection, still inside the read-only transaction: a second checkout could wait forever on
                    // a one-connection pool.
                    let named = try await client.resolvingTypeNames(result, database: database, using: connection)
                    await endCall(on: connection, client: client)
                    return named
                } catch {
                    await endCall(on: connection, client: client)
                    throw error
                }
            }
        }
    }

    /// Opens the read-only transaction. `standard_conforming_strings` is pinned because the guard lexes plain
    /// strings without backslash escapes; with it off on the server, `'\''` would hide SQL from the guard.
    static func readOnlyPreamble(timeout: Double) -> String {
        "BEGIN TRANSACTION READ ONLY; SET LOCAL statement_timeout = \(Int(timeout * 1000)); SET LOCAL standard_conforming_strings = on"
    }

    /// Statements that end an MCP call before its pooled connection is reused: the transaction is rolled back and
    /// the session reset, so nothing a call did (a session advisory lock, a prepared statement, LISTEN, a setting —
    /// also through SQL built at run time that no guard can see) outlives it. `DISCARD ALL` cannot run in a
    /// multi-statement message, hence its own message. Behind a transaction pooler the server connection is shared:
    /// the reset avoids `DISCARD ALL`/`DEALLOCATE ALL`, which would drop the pooler's own prepared statements.
    static func sessionReset(keepsSessionState: Bool) -> [String] {
        keepsSessionState
            ? ["ROLLBACK", "DISCARD ALL"]
            : ["ROLLBACK; SELECT pg_advisory_unlock_all(); UNLISTEN *; RESET ALL"]
    }

    /// Runs `sessionReset`; a connection whose reset fails or that is not idle afterwards is closed, so the pool
    /// drops it instead of handing out a session in an unknown state.
    static func endCall(on connection: PostgresConnection, client: PostgresClient) async {
        do {
            for statement in sessionReset(keepsSessionState: client.serverInfo.keepsSessionState) {
                _ = try await connection.simpleQuery(client.routingPrefix + statement, limits: .metadata)
            }
            if await connection.transactionStatus == .idle { return }
        } catch {}
        await connection.close()
    }

    // MARK: Encoding

    static func encode(result: QueryResult, limitRows: Int) -> [String: JSONValue] {
        guard let rowSet = result.lastRowSet else {
            let tag = result.last?.commandTag
            return ["command": JSONValue(tag?.raw), "affected_rows": JSONValue(tag?.rowCount), "row_count": 0]
        }
        let columns = rowSet.columns.map(ColumnInfoLite.init)
        let encoded = MCPResultEncoder.rows(columns: columns, rows: Array(rowSet.rows.prefix(limitRows)),
                                            truncatedByServer: rowSet.isTruncated || rowSet.rows.count > limitRows)
        return encoded.objectValue ?? [:]
    }

    static func encode(relation: RelationSummary, parent: RelationSummary?) -> JSONValue {
        let kind: String = switch relation.kind {
        case .table: relation.isPartition ? "partition" : "table"
        case .partitionedTable: relation.isPartition ? "partitioned_partition" : "partitioned_table"
        case .view: "view"
        case .materializedView: "materialized_view"
        case .foreignTable: "foreign_table"
        case .sequence: "sequence"
        }
        var result: [String: JSONValue] = [
            "name": .string(relation.name), "schema": .string(relation.schema), "kind": .string(kind),
            "estimated_rows": JSONValue(relation.estimatedRows), "total_bytes": JSONValue(relation.totalBytes),
            "comment": JSONValue(relation.comment), "partition_bound": JSONValue(relation.partitionBound),
            "parent": JSONValue(parent.map { "\($0.schema).\($0.name)" }),
        ]
        if relation.isUnlogged { result["unlogged"] = true }
        if relation.isHypertable { result["timescaledb_hypertable"] = true }
        if let placement = relation.citusPlacement {
            result["citus"] = .string(placement.rawValue)
            result["distribution_column"] = JSONValue(relation.distributionColumn)
        }
        return .object(result.filter { $0.value != .null })
    }

    static func encode(index: IndexInfo) -> JSONValue {
        .object([
            "name": .string(index.name), "definition": .string(index.definition), "method": .string(index.method), "unique": .bool(index.isUnique),
            "primary": .bool(index.isPrimary), "valid": .bool(index.isValid), "size_bytes": JSONValue(index.sizeBytes), "scans": JSONValue(index.scans),
            "unused": .bool(index.isUnused), "estimated_bloat_ratio": JSONValue(index.bloat?.ratio),
        ].filter { $0.value != .null })
    }
}

/// Typed access to tool arguments with clear error messages.
struct MCPArguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let text: String? = switch value {
        case let .string(string): string
        case let .int(number): String(number)
        default: nil
        }
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw MCPToolError("Missing required argument `\(key)`.") }
        return value
    }

    func int(_ key: String, default fallback: Int, range: ClosedRange<Int>) -> Int {
        guard let value = values[key]?.intValue else { return fallback }
        return Int(clamping: min(max(value, Int64(range.lowerBound)), Int64(range.upperBound)))
    }

    func double(_ key: String) -> Double? {
        values[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }
}
