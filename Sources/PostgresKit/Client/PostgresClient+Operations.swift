import Foundation
import PostgresWire

/// Version-aware SQL for operational views (design D9).
public enum OperationsSQL {
    public static func activity(_ version: ServerVersion) -> String {
        let backendType = version.atLeast(10) ? "a.backend_type" : "NULL::text"
        let leader = version.atLeast(13) ? "a.leader_pid" : "NULL::int"
        let queryID = version.atLeast(14) ? "a.query_id::text" : "NULL::text"
        return """
        SELECT a.pid, a.usename, a.datname, a.application_name, a.client_addr::text AS client_addr, \(backendType) AS backend_type,
               a.state, a.wait_event_type, a.wait_event, a.query, \(queryID) AS query_id, \(leader) AS leader_pid,
               extract(epoch FROM now() - a.query_start)::float8 AS query_seconds,
               extract(epoch FROM now() - a.xact_start)::float8 AS xact_seconds,
               extract(epoch FROM now() - a.backend_start)::float8 AS backend_seconds,
               extract(epoch FROM now() - a.state_change)::float8 AS state_seconds,
               pg_blocking_pids(a.pid)::text AS blocked_by, a.backend_xid::text AS backend_xid, a.backend_xmin::text AS backend_xmin,
               a.pid = pg_backend_pid() AS is_self,
               (extract(epoch FROM pg_postmaster_start_time()) * 1000000)::bigint AS node_started_us,
               coalesce(host(inet_server_addr()), '') AS node_addr, coalesce(inet_server_port(), 0) AS node_port
        FROM pg_stat_activity a
        ORDER BY (a.state = 'active') DESC NULLS LAST, a.query_start NULLS LAST
        """
    }

    /// `$1..$3` node fingerprint, `$4` pid. NULL when the statement landed on another node.
    public static func signal(_ function: String) -> String {
        "SELECT CASE WHEN \(NodeFingerprint.matchCondition) THEN \(function)($4::int) END AS signalled"
    }

    public static func locks(_ version: ServerVersion) -> String {
        let wait = version.atLeast(14) ? "extract(epoch FROM now() - l.waitstart)::float8" : "CASE WHEN NOT l.granted THEN extract(epoch FROM now() - a.query_start)::float8 END"
        return """
        SELECT l.pid, l.locktype, CASE WHEN l.relation IS NOT NULL THEN l.relation::regclass::text END AS relation, l.mode, l.granted,
               concat_ws(' ', CASE WHEN l.transactionid IS NOT NULL THEN 'xid ' || l.transactionid END,
                              CASE WHEN l.virtualxid IS NOT NULL THEN 'vxid ' || l.virtualxid END,
                              CASE WHEN l.page IS NOT NULL THEN 'page ' || l.page END,
                              CASE WHEN l.tuple IS NOT NULL THEN 'tuple ' || l.tuple END,
                              CASE WHEN l.locktype = 'advisory' THEN 'key ' || l.classid || ':' || l.objid END) AS detail,
               a.usename, a.query, a.state, \(wait) AS wait_seconds
        FROM pg_locks l LEFT JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE l.pid IS DISTINCT FROM pg_backend_pid()
        ORDER BY l.granted, l.pid
        """
    }

    public static func currentLSN(_ version: ServerVersion, inRecovery: Bool) -> String {
        if version.atLeast(10) { return inRecovery ? "pg_last_wal_replay_lsn()" : "pg_current_wal_lsn()" }
        return inRecovery ? "pg_last_xlog_replay_location()" : "pg_current_xlog_location()"
    }

    static func lsnDiff(_ version: ServerVersion) -> String { version.atLeast(10) ? "pg_wal_lsn_diff" : "pg_xlog_location_diff" }

    public static func replication(_ version: ServerVersion, inRecovery: Bool) -> String {
        let current = currentLSN(version, inRecovery: inRecovery)
        let diff = lsnDiff(version)
        if version.atLeast(10) {
            return """
            SELECT pid, usename, application_name, client_addr::text AS client_addr, state, sync_state,
                   sent_lsn::text AS sent_lsn, write_lsn::text AS write_lsn, flush_lsn::text AS flush_lsn, replay_lsn::text AS replay_lsn,
                   \(diff)(\(current), replay_lsn)::bigint AS replay_lag_bytes,
                   extract(epoch FROM write_lag)::float8 AS write_lag, extract(epoch FROM flush_lag)::float8 AS flush_lag,
                   extract(epoch FROM replay_lag)::float8 AS replay_lag
            FROM pg_stat_replication ORDER BY application_name
            """
        }
        return """
        SELECT pid, usename, application_name, client_addr::text AS client_addr, state, sync_state,
               sent_location::text AS sent_lsn, write_location::text AS write_lsn, flush_location::text AS flush_lsn,
               replay_location::text AS replay_lsn, \(diff)(\(current), replay_location)::bigint AS replay_lag_bytes,
               NULL::float8 AS write_lag, NULL::float8 AS flush_lag, NULL::float8 AS replay_lag
        FROM pg_stat_replication ORDER BY application_name
        """
    }

    public static func slots(_ version: ServerVersion, inRecovery: Bool) -> String {
        let current = currentLSN(version, inRecovery: inRecovery)
        let temporary = version.atLeast(10) ? "temporary" : "false"
        let walStatus = version.atLeast(13) ? "wal_status, safe_wal_size" : "NULL::text AS wal_status, NULL::bigint AS safe_wal_size"
        return """
        SELECT slot_name, plugin, slot_type, database, active, active_pid, \(temporary) AS temporary,
               restart_lsn::text AS restart_lsn, confirmed_flush_lsn::text AS confirmed_flush_lsn,
               CASE WHEN restart_lsn IS NOT NULL THEN \(lsnDiff(version))(\(current), restart_lsn)::bigint END AS retained_bytes, \(walStatus)
        FROM pg_replication_slots ORDER BY slot_name
        """
    }

    public static func standby(_ version: ServerVersion) -> String {
        let receive = version.atLeast(10) ? "pg_last_wal_receive_lsn()" : "pg_last_xlog_receive_location()"
        let replay = version.atLeast(10) ? "pg_last_wal_replay_lsn()" : "pg_last_xlog_replay_location()"
        let paused = version.atLeast(10) ? "pg_is_wal_replay_paused()" : "pg_is_xlog_replay_paused()"
        let sender = version.atLeast(11) ? "(SELECT sender_host || ':' || sender_port FROM pg_stat_wal_receiver LIMIT 1)" : "NULL::text"
        return """
        SELECT \(receive)::text AS receive_lsn, \(replay)::text AS replay_lsn,
               extract(epoch FROM now() - pg_last_xact_replay_timestamp())::float8 AS replay_delay, \(paused) AS paused,
               \(sender) AS upstream, (SELECT status FROM pg_stat_wal_receiver LIMIT 1) AS receiver_status
        """
    }

    /// `(command, view, fraction SQL)` for the progress views available on `version`.
    public static func progressViews(_ version: ServerVersion) -> [(command: String, view: String, fraction: String, columns: [String])] {
        var views: [(String, String, String, [String])] = [
            ("VACUUM", "pg_stat_progress_vacuum", "CASE WHEN p.heap_blks_total > 0 THEN p.heap_blks_scanned::float8 / p.heap_blks_total END",
             ["heap_blks_total", "heap_blks_scanned", "heap_blks_vacuumed", "index_vacuum_count"]),
        ]
        if version.atLeast(12) {
            views.append(("CREATE INDEX", "pg_stat_progress_create_index",
                          "CASE WHEN p.blocks_total > 0 THEN p.blocks_done::float8 / p.blocks_total WHEN p.tuples_total > 0 THEN p.tuples_done::float8 / p.tuples_total END",
                          ["command", "blocks_total", "blocks_done", "tuples_total", "tuples_done", "lockers_total", "lockers_done"]))
            views.append(("CLUSTER", "pg_stat_progress_cluster",
                          "CASE WHEN p.heap_blks_total > 0 THEN p.heap_blks_scanned::float8 / p.heap_blks_total END",
                          ["command", "heap_tuples_scanned", "heap_tuples_written", "heap_blks_total", "heap_blks_scanned"]))
        }
        if version.atLeast(13) {
            views.append(("ANALYZE", "pg_stat_progress_analyze",
                          "CASE WHEN p.sample_blks_total > 0 THEN p.sample_blks_scanned::float8 / p.sample_blks_total END",
                          ["sample_blks_total", "sample_blks_scanned", "child_tables_total", "child_tables_done"]))
            views.append(("BASE BACKUP", "pg_stat_progress_basebackup",
                          "CASE WHEN p.backup_total > 0 THEN p.backup_streamed::float8 / p.backup_total END",
                          ["backup_total", "backup_streamed", "tablespaces_total", "tablespaces_streamed"]))
        }
        if version.atLeast(14) {
            views.append(("COPY", "pg_stat_progress_copy",
                          "CASE WHEN p.bytes_total > 0 THEN p.bytes_processed::float8 / p.bytes_total END",
                          ["command", "type", "bytes_processed", "bytes_total", "tuples_processed", "tuples_excluded"]))
        }
        return views
    }

    /// `pg_stat_progress_basebackup` has no database or relation columns.
    public static func progress(view: String, fraction: String, columns: [String], hasRelation: Bool, hasPhase: Bool) -> String {
        let detailColumns = columns.map { "p.\($0)::text AS \($0)" }.joined(separator: ", ")
        let relation = hasRelation ? "CASE WHEN p.relid <> 0 THEN p.relid::regclass::text END" : "NULL::text"
        let database = hasRelation ? "p.datname" : "NULL::name AS datname"
        let phase = hasPhase ? "p.phase" : "NULL::text"
        return """
        SELECT p.pid, \(database), \(relation) AS relation, \(phase) AS phase, (\(fraction))::float8 AS fraction, \(detailColumns), a.query
        FROM \(view) p LEFT JOIN pg_stat_activity a ON a.pid = p.pid
        """
    }

    public static let settings = """
        SELECT name, setting, unit, category, short_desc, source, boot_val, reset_val, context, pending_restart
        FROM pg_settings ORDER BY category, name
        """

    public static let roles = """
        SELECT r.rolname, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolreplication, r.rolbypassrls,
               r.rolconnlimit, r.rolvaliduntil::text AS valid_until,
               ARRAY(SELECT b.rolname FROM pg_auth_members m JOIN pg_roles b ON m.roleid = b.oid WHERE m.member = r.oid ORDER BY 1)::text AS member_of,
               shobj_description(r.oid, 'pg_authid') AS comment
        FROM pg_roles r ORDER BY r.rolname
        """

    public static func overview(_ version: ServerVersion) -> String {
        let checkpoints = version.atLeast(17)
            ? "(SELECT num_timed FROM pg_stat_checkpointer) AS checkpoints_timed, (SELECT num_requested FROM pg_stat_checkpointer) AS checkpoints_req"
            : "(SELECT checkpoints_timed FROM pg_stat_bgwriter) AS checkpoints_timed, (SELECT checkpoints_req FROM pg_stat_bgwriter) AS checkpoints_req"
        return """
        SELECT extract(epoch FROM now() - pg_postmaster_start_time())::float8 AS uptime,
               current_setting('max_connections') AS max_connections,
               (SELECT max(age(datfrozenxid)) FROM pg_database) AS max_xid_age, \(checkpoints)
        """
    }

    public static let connectionStates = """
        SELECT coalesce(state, 'background') AS state, count(*) AS n FROM pg_stat_activity GROUP BY 1
        """

    public static let databaseStatistics = """
        SELECT s.datname, s.numbackends, s.xact_commit, s.xact_rollback, s.blks_read, s.blks_hit, s.deadlocks, s.temp_bytes, s.conflicts,
               CASE WHEN has_database_privilege(d.oid, 'CONNECT') THEN pg_database_size(d.oid) END AS size_bytes, age(d.datfrozenxid) AS xid_age
        FROM pg_stat_database s JOIN pg_database d ON d.oid = s.datid
        WHERE NOT d.datistemplate ORDER BY s.datname
        """

    public static let maintenance = """
        SELECT s.schemaname, s.relname, s.n_live_tup, s.n_dead_tup, greatest(s.last_vacuum, s.last_autovacuum) AS last_vacuum,
               greatest(s.last_analyze, s.last_autoanalyze) AS last_analyze, age(c.relfrozenxid) AS xid_age, pg_total_relation_size(s.relid) AS total_bytes
        FROM pg_stat_user_tables s JOIN pg_class c ON c.oid = s.relid
        ORDER BY s.n_dead_tup DESC NULLS LAST, age(c.relfrozenxid) DESC LIMIT $1::int
        """

    public static let unusedIndexes = """
        SELECT s.schemaname, s.relname, s.indexrelname, s.idx_scan, pg_relation_size(s.indexrelid) AS size_bytes, i.indisunique
        FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
        WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
          AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = s.indexrelid)
        ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT $1::int
        """
}

extension PostgresClient {
    /// `pg_stat_activity` with blocking pids, taken on the primary behind Pgpool. Records the node for guarded signals.
    public func activity() async throws -> ActivitySnapshot {
        let rows = try await records(routingPrefix + OperationsSQL.activity(serverInfo.version))
        let node = rows.first.flatMap { row in
            row.int("node_started_us").map {
                NodeFingerprint(postmasterStartMicros: $0, serverAddress: row.text("node_addr") ?? "", serverPort: Int(clamping: row.int("node_port") ?? 0))
            }
        }
        return ActivitySnapshot(sessions: rows.compactMap(OperationsParser.session), node: node ?? serverInfo.node)
    }

    /// Cancels the running query of `pid` (`pg_cancel_backend`) on the node of `snapshot`.
    public func cancelBackend(_ pid: Int32, observedOn node: NodeFingerprint?) async throws -> Bool {
        try await signalBackend("pg_cancel_backend", pid: pid, node: node)
    }

    /// Terminates the session of `pid` (`pg_terminate_backend`) on the node of `snapshot`.
    public func terminateBackend(_ pid: Int32, observedOn node: NodeFingerprint?) async throws -> Bool {
        try await signalBackend("pg_terminate_backend", pid: pid, node: node)
    }

    /// Runs the signal as one guarded statement so it only fires on the node where the pid was observed (design D10).
    /// Behind a load balancer each new connection may land elsewhere: retry a few times with fresh connections.
    func signalBackend(_ function: String, pid: Int32, node: NodeFingerprint?) async throws -> Bool {
        guard let node = node ?? serverInfo.node else {
            throw PostgresError(.unsupported, "The server did not report its identity; cannot make sure the signal reaches the right server.")
        }
        let sql = ServerInfo.noLoadBalance + OperationsSQL.signal(function)
        let parameters = node.bindValues + [.text(String(pid))]
        for _ in 0..<8 {
            let connection = try await makeConnection()
            defer { Task { await connection.close() } }
            let row = try await Self.withTimeout(20) {
                try await connection.extendedQuery(sql, parameters: parameters).records.first
            }
            guard let value = row?.raw("signalled") else { continue } // NULL: another node answered
            return PostgresText.bool(value) ?? false
        }
        throw PostgresError(.server, "Could not reach the server the session runs on through \(configuration.endpoint) (it looks like a load balancer). Connect to that server directly to signal backend \(pid).")
    }

    public func locks() async throws -> [LockInfo] {
        try await records(routingPrefix + OperationsSQL.locks(serverInfo.version)).compactMap(OperationsParser.lock)
    }

    public func replication() async throws -> ReplicationOverview {
        let version = serverInfo.version
        let inRecovery = try await records(routingPrefix + "SELECT pg_is_in_recovery() AS r").first?.bool("r") ?? serverInfo.isInRecovery
        let prefix = routingPrefix
        async let connectionRows = records(prefix + OperationsSQL.replication(version, inRecovery: inRecovery))
        async let slotRows = records(prefix + OperationsSQL.slots(version, inRecovery: inRecovery))
        async let lsnRows = records(prefix + "SELECT \(OperationsSQL.currentLSN(version, inRecovery: inRecovery))::text AS lsn")
        var standby: StandbyStatus?
        if inRecovery, let row = try await records(prefix + OperationsSQL.standby(version)).first {
            standby = StandbyStatus(receiveLSN: row.text("receive_lsn"), replayLSN: row.text("replay_lsn"), replayDelaySeconds: row.double("replay_delay"),
                                    isReplayPaused: row.bool("paused"), upstream: row.text("upstream"), receiverStatus: row.text("receiver_status"))
        }
        return ReplicationOverview(isInRecovery: inRecovery, currentLSN: try await lsnRows.first?.text("lsn"),
                                   connections: try await connectionRows.compactMap(OperationsParser.replicationConnection),
                                   slots: try await slotRows.compactMap(OperationsParser.slot), standby: standby)
    }

    /// Running maintenance commands from every `pg_stat_progress_*` view this version has.
    public func progress() async throws -> [ProgressEntry] {
        var entries: [ProgressEntry] = []
        for view in OperationsSQL.progressViews(serverInfo.version) {
            let hasRelation = view.view != "pg_stat_progress_basebackup"
            let hasPhase = view.view != "pg_stat_progress_copy" // COPY reports command/type instead
            let sql = OperationsSQL.progress(view: view.view, fraction: view.fraction, columns: view.columns, hasRelation: hasRelation, hasPhase: hasPhase)
            let rows = try await records(routingPrefix + sql)
            entries += rows.compactMap { row in
                guard let pid = row.int("pid").flatMap({ Int32(exactly: $0) }) else { return nil }
                let details = view.columns.compactMap { column in row.text(column).map { ProgressDetail(name: column, value: $0) } }
                return ProgressEntry(command: view.command, pid: pid, database: row.text("datname"), relation: row.text("relation"),
                                     phase: row.text("phase"), fraction: row.double("fraction").map { min(1, max(0, $0)) }, details: details,
                                     query: row.string("query"))
            }
        }
        return entries
    }

    /// Where pg_stat_statements lives in `database`, if installed.
    public func statementStatisticsSchema(database: String? = nil) async throws -> String? {
        try await installedExtensions(database: database).first { $0.name == "pg_stat_statements" }?.schema
    }

    /// Top statements by total execution time from pg_stat_statements.
    public func topStatements(limit: Int = 100, database: String? = nil) async throws -> (StatementStatisticsAvailability, [StatementStatistics]) {
        guard let schema = try await statementStatisticsSchema(database: database) else { return (.extensionMissing, []) }
        let view = SQLText.qualified(schema, "pg_stat_statements")
        let columns = try await records("""
            SELECT a.attname FROM pg_attribute a WHERE a.attrelid = $1::regclass AND a.attnum > 0 AND NOT a.attisdropped
            """, [.text(view)], database: database).compactMap { $0.text("attname") }
        let names = Set(columns)
        let total = names.contains("total_exec_time") ? "total_exec_time" : "total_time"
        let mean = names.contains("mean_exec_time") ? "mean_exec_time" : (names.contains("mean_time") ? "mean_time" : "NULL::float8")
        let max = names.contains("max_exec_time") ? "max_exec_time" : (names.contains("max_time") ? "max_time" : "NULL::float8")
        let queryID = names.contains("queryid") ? "s.queryid::text" : "NULL::text"
        let sql = """
            SELECT \(queryID) AS queryid, s.query, r.rolname, d.datname, s.calls, s.\(total)::float8 AS total_ms, \(mean)::float8 AS mean_ms,
                   \(max)::float8 AS max_ms, s.rows, s.shared_blks_hit, s.shared_blks_read, s.temp_blks_written
            FROM \(view) s LEFT JOIN pg_roles r ON r.oid = s.userid LEFT JOIN pg_database d ON d.oid = s.dbid
            ORDER BY s.\(total) DESC LIMIT $1::int
            """
        do {
            let rows = try await records(sql, [.text(String(min(Swift.max(1, limit), 1_000)))], database: database)
            return (.available, rows.compactMap(OperationsParser.statement))
        } catch let error as PostgresError where error.kind == .server {
            if error.message.contains("shared_preload_libraries") { return (.notPreloaded(error.message), []) }
            return (.failed(error.message), [])
        }
    }

    public func settings() async throws -> [ServerSetting] {
        try await records(OperationsSQL.settings).compactMap { row in
            guard let name = row.text("name") else { return nil }
            return ServerSetting(name: name, setting: row.string("setting"), unit: row.text("unit"), category: row.text("category"),
                                 description: row.text("short_desc"), source: row.text("source"), bootValue: row.string("boot_val"),
                                 resetValue: row.string("reset_val"), context: row.text("context"), pendingRestart: row.bool("pending_restart") ?? false)
        }
    }

    public func roles() async throws -> [RoleInfo] {
        try await records(OperationsSQL.roles).compactMap { row in
            guard let name = row.raw("rolname") else { return nil }
            return RoleInfo(name: name, isSuperuser: row.bool("rolsuper") ?? false, canLogin: row.bool("rolcanlogin") ?? false,
                            canCreateRole: row.bool("rolcreaterole") ?? false, canCreateDatabase: row.bool("rolcreatedb") ?? false,
                            isReplication: row.bool("rolreplication") ?? false, bypassesRLS: row.bool("rolbypassrls") ?? false,
                            inherits: row.bool("rolinherit") ?? true, connectionLimit: row.int("rolconnlimit").map { Int(clamping: $0) },
                            validUntil: row.text("valid_until"), memberOf: row.array("member_of"), comment: row.string("comment"))
        }
    }

    public func overview() async throws -> ServerOverview {
        let prefix = routingPrefix
        async let headRows = records(prefix + OperationsSQL.overview(serverInfo.version))
        async let stateRows = records(prefix + OperationsSQL.connectionStates)
        async let databaseRows = records(prefix + OperationsSQL.databaseStatistics)
        let head = try await headRows.first
        var states: [String: Int] = [:]
        for row in try await stateRows {
            if let state = row.text("state") { states[state] = Int(clamping: row.int("n") ?? 0) }
        }
        let databases: [DatabaseStatistics] = try await databaseRows.compactMap { row in
            guard let name = row.text("datname") else { return nil }
            return DatabaseStatistics(name: name, backends: Int(clamping: row.int("numbackends") ?? 0), commits: row.int("xact_commit"),
                                      rollbacks: row.int("xact_rollback"), blocksRead: row.int("blks_read"), blocksHit: row.int("blks_hit"),
                                      deadlocks: row.int("deadlocks"), tempBytes: row.int("temp_bytes"), conflicts: row.int("conflicts"),
                                      sizeBytes: row.int("size_bytes"), transactionIDAge: row.int("xid_age"))
        }
        return ServerOverview(uptimeSeconds: head?.double("uptime"), connectionsByState: states,
                              maxConnections: head?.int("max_connections").map { Int(clamping: $0) }, databases: databases,
                              maxTransactionIDAge: head?.int("max_xid_age"), checkpointsTimed: head?.int("checkpoints_timed"),
                              checkpointsRequested: head?.int("checkpoints_req"))
    }

    public func maintenanceCandidates(limit: Int = 50, database: String? = nil) async throws -> [MaintenanceCandidate] {
        try await records(OperationsSQL.maintenance, [.text(String(min(max(1, limit), 1_000)))], database: database).compactMap { row in
            guard let schema = row.text("schemaname"), let name = row.raw("relname") else { return nil }
            return MaintenanceCandidate(schema: schema, name: name, liveTuples: row.int("n_live_tup"), deadTuples: row.int("n_dead_tup"),
                                        lastVacuum: row.date("last_vacuum"), lastAnalyze: row.date("last_analyze"),
                                        transactionIDAge: row.int("xid_age"), totalBytes: row.int("total_bytes"))
        }
    }

    public func unusedIndexes(limit: Int = 100, database: String? = nil) async throws -> [IndexUsage] {
        try await records(OperationsSQL.unusedIndexes, [.text(String(min(max(1, limit), 1_000)))], database: database).compactMap { row in
            guard let schema = row.text("schemaname"), let table = row.raw("relname"), let index = row.raw("indexrelname") else { return nil }
            return IndexUsage(schema: schema, table: table, index: index, scans: row.int("idx_scan") ?? 0, sizeBytes: row.int("size_bytes"),
                              isUnique: row.bool("indisunique") ?? false)
        }
    }

    /// PgBouncer console or Pgpool `SHOW …` output as a plain result.
    public func poolerReport(_ command: String) async throws -> QueryResult {
        let allowed = ["POOLS", "STATS", "CLIENTS", "SERVERS", "DATABASES", "CONFIG", "LISTS", "POOL_NODES", "POOL_PROCESSES", "POOL_POOLS", "POOL_HEALTH_CHECK_STATS"]
        let word = command.uppercased()
        guard allowed.contains(word) else { throw PostgresError(.invalidArgument, "Unsupported pooler report \(command)") }
        return try await simpleQuery("SHOW \(word)")
    }
}

/// Record → model conversions for operations (pure; unit-tested).
public enum OperationsParser {
    public static func pids(_ text: String?) -> [Int32] {
        guard let text else { return [] }
        return PostgresArray.parse(text).compactMap { Int32($0) }
    }

    public static func session(_ row: Record) -> ActivitySession? {
        guard let pid = row.int("pid").flatMap({ Int32(exactly: $0) }) else { return nil }
        return ActivitySession(pid: pid, user: row.text("usename"), database: row.text("datname"), applicationName: row.text("application_name"),
                               clientAddress: row.text("client_addr"), backendType: row.text("backend_type"), state: row.text("state"),
                               waitEventType: row.text("wait_event_type"), waitEvent: row.text("wait_event"), query: row.string("query"),
                               queryID: row.text("query_id"), querySeconds: row.double("query_seconds"), transactionSeconds: row.double("xact_seconds"),
                               backendSeconds: row.double("backend_seconds"), stateSeconds: row.double("state_seconds"),
                               blockedBy: pids(row.raw("blocked_by")), leaderPID: row.int("leader_pid").flatMap { Int32(exactly: $0) },
                               backendXID: row.text("backend_xid"), backendXmin: row.text("backend_xmin"), isCurrentSession: row.bool("is_self") ?? false)
    }

    public static func lock(_ row: Record) -> LockInfo? {
        guard let type = row.text("locktype"), let mode = row.text("mode") else { return nil }
        return LockInfo(pid: row.int("pid").flatMap { Int32(exactly: $0) }, lockType: type, relation: row.text("relation"), mode: mode,
                        granted: row.bool("granted") ?? false, objectDetail: row.text("detail"), user: row.text("usename"),
                        query: row.string("query"), state: row.text("state"), waitSeconds: row.double("wait_seconds"))
    }

    public static func replicationConnection(_ row: Record) -> ReplicationConnection? {
        guard let pid = row.int("pid").flatMap({ Int32(exactly: $0) }) else { return nil }
        return ReplicationConnection(pid: pid, user: row.text("usename"), applicationName: row.text("application_name"),
                                     clientAddress: row.text("client_addr"), state: row.text("state"), syncState: row.text("sync_state"),
                                     sentLSN: row.text("sent_lsn"), writeLSN: row.text("write_lsn"), flushLSN: row.text("flush_lsn"),
                                     replayLSN: row.text("replay_lsn"), replayLagBytes: row.int("replay_lag_bytes"),
                                     writeLagSeconds: row.double("write_lag"), flushLagSeconds: row.double("flush_lag"),
                                     replayLagSeconds: row.double("replay_lag"))
    }

    public static func slot(_ row: Record) -> ReplicationSlot? {
        guard let name = row.text("slot_name") else { return nil }
        return ReplicationSlot(name: name, plugin: row.text("plugin"), slotType: row.text("slot_type") ?? "", database: row.text("database"),
                               isActive: row.bool("active") ?? false, activePID: row.int("active_pid").flatMap { Int32(exactly: $0) },
                               isTemporary: row.bool("temporary") ?? false, restartLSN: row.text("restart_lsn"),
                               confirmedFlushLSN: row.text("confirmed_flush_lsn"), retainedBytes: row.int("retained_bytes"),
                               walStatus: row.text("wal_status"), safeWALBytes: row.int("safe_wal_size"))
    }

    public static func statement(_ row: Record) -> StatementStatistics? {
        guard let query = row.string("query") else { return nil }
        return StatementStatistics(queryID: row.text("queryid"), query: query, user: row.text("rolname"), database: row.text("datname"),
                                   calls: row.int("calls") ?? 0, totalMilliseconds: row.double("total_ms") ?? 0, meanMilliseconds: row.double("mean_ms"),
                                   maxMilliseconds: row.double("max_ms"), rows: row.int("rows"), sharedBlocksHit: row.int("shared_blks_hit"),
                                   sharedBlocksRead: row.int("shared_blks_read"), tempBlocksWritten: row.int("temp_blks_written"))
    }
}
