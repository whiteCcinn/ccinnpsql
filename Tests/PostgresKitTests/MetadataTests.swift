import Foundation
import Testing
@testable import PostgresKit
import PostgresWire

@Suite("Session settings")
struct SessionSettingsTests {
    @Test func classifiesStatements() {
        #expect(SessionSettingChange.parse("SET search_path TO app, public;") == .set(name: "search_path", statement: "SET search_path TO app, public"))
        #expect(SessionSettingChange.parse("-- c\nset session statement_timeout = '5s'") == .set(name: "statement_timeout", statement: "set session statement_timeout = '5s'"))
        #expect(SessionSettingChange.parse("SET ROLE reporting") == .set(name: "role", statement: "SET ROLE reporting"))
        #expect(SessionSettingChange.parse("SET TIME ZONE 'UTC'") == .set(name: "timezone", statement: "SET TIME ZONE 'UTC'"))
        #expect(SessionSettingChange.parse("SET SESSION AUTHORIZATION bob") == .set(name: "session_authorization", statement: "SET SESSION AUTHORIZATION bob"))
        #expect(SessionSettingChange.parse("SET work_mem='64MB'") == .set(name: "work_mem", statement: "SET work_mem='64MB'"))
        #expect(SessionSettingChange.parse("SET LOCAL work_mem = '1MB'") == nil)
        #expect(SessionSettingChange.parse("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE") == nil)
        #expect(SessionSettingChange.parse("SET CONSTRAINTS ALL DEFERRED") == nil)
        #expect(SessionSettingChange.parse("RESET work_mem") == .reset(name: "work_mem"))
        #expect(SessionSettingChange.parse("RESET ALL") == .resetAll)
        #expect(SessionSettingChange.parse("DISCARD ALL") == .resetAll)
        #expect(SessionSettingChange.parse("COMMIT") == .commit)
        #expect(SessionSettingChange.parse("ROLLBACK") == .rollback)
        #expect(SessionSettingChange.parse("ROLLBACK TO SAVEPOINT a") == nil)
        #expect(SessionSettingChange.parse("SELECT set_config('app.user', 'x', false)") == .set(name: "app.user", statement: "SELECT set_config('app.user', 'x', false)"))
        #expect(SessionSettingChange.parse("SELECT set_config('app.user', 'x', true)") == nil)
        #expect(SessionSettingChange.parse("SELECT 1") == nil)
        #expect(SessionSettingChange.parse("/* unterminated") == nil)
    }

    @Test func transactionsDecideWhatSticks() {
        var log = SessionSettingsLog()
        log.record("SET search_path TO a", inTransaction: false)
        log.record("BEGIN", inTransaction: true)
        log.record("SET work_mem = '1GB'", inTransaction: true)
        log.record("ROLLBACK", inTransaction: false)
        #expect(log.replayStatements == ["SET search_path TO a"])
        log.record("BEGIN", inTransaction: true)
        log.record("SET work_mem = '2GB'", inTransaction: true)
        log.record("COMMIT", inTransaction: false)
        log.record("SET search_path TO b", inTransaction: false)
        #expect(log.replayStatements == ["SET work_mem = '2GB'", "SET search_path TO b"])
        log.record("RESET work_mem", inTransaction: false)
        #expect(log.replayStatements == ["SET search_path TO b"])
        log.record("BEGIN", inTransaction: true)
        log.record("SET x.y = 1", inTransaction: true)
        log.discardPending() // the transaction failed
        log.record("COMMIT", inTransaction: false)
        #expect(log.replayStatements == ["SET search_path TO b"])
        log.record("DISCARD ALL", inTransaction: false)
        #expect(log.replayStatements.isEmpty)
    }

    @Test func boundedLog() {
        var log = SessionSettingsLog()
        for index in 0..<200 { log.record("SET app.v\(index) = 1", inTransaction: false) }
        #expect(log.replayStatements.count == SessionSettingsLog.maxSettings)
        #expect(log.replayStatements.last == "SET app.v199 = 1")
    }

    @Test func scriptSplitterRespectsQuoting() {
        let script = "SET a = 1; SELECT ';' AS x; DO $$ BEGIN PERFORM 1; END $$; /* ; */ SELECT \"a;b\" FROM t; -- ;\nSET b = 2"
        #expect(SimpleStatementSplitter.split(script) == [
            "SET a = 1", "SELECT ';' AS x", "DO $$ BEGIN PERFORM 1; END $$", "SELECT \"a;b\" FROM t", "SET b = 2",
        ])
    }
}

@Suite("Versions and SQL generation")
struct VersionTests {
    @Test func parsesVersions() {
        #expect(ServerVersion(number: 170_002).description == "17.2")
        #expect(ServerVersion(number: 90_624).description == "9.6.24")
        #expect(ServerVersion(number: 90_624).majorRelease == "9.6")
        #expect(ServerVersion(text: "16.4 (Debian 16.4-1.pgdg120+2)")?.number == 160_004)
        #expect(ServerVersion(text: "9.6.24")?.number == 90_624)
        #expect(ServerVersion(text: "18beta1")?.major == 18)
        #expect(ServerVersion(text: "1.23.1/bouncer")?.major == 1)
        #expect(ServerVersion(text: "garbage") == nil)
        #expect(ServerVersion(number: 100_000).atLeast(10))
        #expect(!ServerVersion(number: 90_624).atLeast(10))
    }

    @Test func catalogSQLDependsOnVersion() {
        let old = ServerVersion(major: 9, minor: 6)
        let modern = ServerVersion(major: 17)
        #expect(!CatalogSQL.relations(old).contains("c.relispartition"))
        #expect(CatalogSQL.relations(modern).contains("c.relispartition"))
        #expect(CatalogSQL.routines(old).contains("proisagg"))
        #expect(CatalogSQL.routines(modern).contains("prokind"))
        #expect(OperationsSQL.replication(old, inRecovery: false).contains("pg_current_xlog_location()"))
        #expect(OperationsSQL.replication(modern, inRecovery: false).contains("pg_current_wal_lsn()"))
        #expect(OperationsSQL.replication(modern, inRecovery: true).contains("pg_last_wal_replay_lsn()"))
        #expect(OperationsSQL.progressViews(old).map(\.command) == ["VACUUM"])
        #expect(OperationsSQL.progressViews(modern).count == 6)
        #expect(OperationsSQL.activity(old).contains("NULL::text AS backend_type"))
        #expect(OperationsSQL.overview(modern).contains("pg_stat_checkpointer"))
        #expect(OperationsSQL.overview(ServerVersion(major: 16)).contains("pg_stat_bgwriter"))
        #expect(InsightSQL.columns(old).contains("''::text AS identity"))
        #expect(InsightSQL.columns(modern).contains("a.attgenerated"))
        #expect(InsightSQL.sequence(old).contains("NULL::bigint AS start_value"))
        // Review finding 6: pg_range.rngmultitypid exists only on PostgreSQL 14+.
        #expect(!InsightSQL.rangeSubtype(ServerVersion(major: 13)).contains("rngmultitypid"))
        #expect(!InsightSQL.rangeSubtype(old).contains("rngmultitypid"))
        #expect(InsightSQL.rangeSubtype(ServerVersion(major: 14)).contains("rngmultitypid"))
        #expect(CatalogSQL.hypertables(extensionVersion: "1.7.5").hasSuffix("timescaledb_information.hypertable"))
        #expect(CatalogSQL.hypertables(extensionVersion: "2.17.2").contains("timescaledb_information.hypertables"))
    }

    @Test func signalStatementIsGuardedByTheNode() {
        let sql = OperationsSQL.signal("pg_terminate_backend")
        #expect(sql.contains("pg_postmaster_start_time()"))
        #expect(sql.contains("inet_server_addr()"))
        #expect(sql.contains("THEN pg_terminate_backend($4::int) END"))
    }
}

@Suite("Catalog models")
struct CatalogModelTests {
    func relation(_ oid: UInt32, _ name: String, kind: RelationKind = .table, parent: UInt32? = nil, bytes: Int64? = 100) -> RelationSummary {
        RelationSummary(oid: oid, schema: "s", name: name, kind: kind, isPartition: parent != nil, parentOID: parent, totalBytes: bytes)
    }

    @Test func nestsPartitionsAndSurvivesCycles() {
        let relations = [
            relation(1, "measurements", kind: .partitionedTable, bytes: nil),
            relation(2, "m_2025", parent: 1), relation(3, "m_2026", parent: 1),
            relation(4, "m_2026_q1", parent: 3),
            relation(5, "orphan", parent: 999),
            relation(6, "a", parent: 7), relation(7, "b", parent: 6), // corrupt cycle
        ]
        let tree = RelationNode.tree(relations)
        let root = tree.first { $0.relation.name == "measurements" }
        #expect(root?.children.map(\.relation.name) == ["m_2025", "m_2026"])
        #expect(root?.children.last?.children.map(\.relation.name) == ["m_2026_q1"])
        #expect(root?.totalBytesIncludingChildren == 300)
        #expect(tree.contains { $0.relation.name == "orphan" })
        let all = Set(tree.flatMap { [$0.relation.name] + $0.children.map(\.relation.name) + $0.children.flatMap { $0.children.map(\.relation.name) } })
        #expect(all.isSuperset(of: ["a", "b"]))
        let withTotals = CatalogParser.withPartitionTotals(relations)
        #expect(withTotals.first?.totalBytes == 300)
    }

    @Test func parsesRows() {
        let row = Record(["oid": "16384", "schema": "public", "name": "t", "relkind": "p", "persistence": "u", "relispartition": "f",
                          "partition_bound": nil, "relhassubclass": "t", "reltuples": "-1", "total_bytes": nil, "owner": "app", "comment": nil,
                          "parent_oid": nil])
        let parsed = CatalogParser.relation(row)
        #expect(parsed?.kind == .partitionedTable)
        #expect(parsed?.isUnlogged == true)
        #expect(parsed?.estimatedRows == nil) // never analyzed
        #expect(CatalogParser.relation(Record(["oid": "x", "schema": "s", "name": "n", "relkind": "r"])) == nil)
        #expect(CatalogParser.relation(Record(["oid": "1", "schema": "s", "name": "n", "relkind": "?"])) == nil)
        let routine = CatalogParser.routine(Record(["oid": "1", "schema": "s", "name": "f", "kind": "p", "arguments": "a integer",
                                                    "result": nil, "language": "plpgsql", "volatility": "v"]))
        #expect(routine?.kind == .procedure)
        #expect(routine?.signature == "f(a integer)")
    }

    @Test func arraysAndTypes() {
        #expect(PostgresArray.parse("{a,b,\"c d\",NULL,\"NULL\"}") == ["a", "b", "c d", "NULL"])
        #expect(PostgresArray.parse("{}") == [])
        #expect(PostgresArray.parse("{\"a\\\"b\"}") == ["a\"b"])
        #expect(PostgresArray.parse("not an array") == [])
        #expect(OperationsParser.pids("{12,34}") == [12, 34])
        #expect(OperationsParser.pids(nil) == [])
        #expect(ColumnDescription(name: "v", typeOID: 1043, typeModifier: 24).displayType == "varchar(20)")
        #expect(ColumnDescription(name: "n", typeOID: 1700, typeModifier: (10 << 16 | 2) + 4).displayType == "numeric(10,2)")
        #expect(ColumnDescription(name: "a", typeOID: 1007).displayType == "int4[]")
        #expect(ColumnDescription(name: "a", typeOID: 1007).kind == .array)
        #expect(ColumnDescription(name: "g", typeOID: 99_999, typeName: "geometry").displayType == "geometry")
        #expect(ByteFormat.string(512) == "512 bytes")
        #expect(ByteFormat.string(1_536) == "1.5 kB")
        #expect(ByteFormat.string(33_554_432) == "32.0 MB")
    }

    @Test func sequenceHeadroom() {
        let ascending = SequenceInfo(dataType: "integer", startValue: 1, increment: 1, minValue: 1, maxValue: 100, cache: 1, cycles: false,
                                     lastValue: 90, ownedBy: nil)
        #expect((ascending.usedFraction ?? 0) > 0.89)
        #expect(ascending.isNearlyExhausted)
        let descending = SequenceInfo(dataType: "integer", startValue: -1, increment: -1, minValue: -100, maxValue: -1, cache: 1, cycles: false,
                                      lastValue: -10, ownedBy: nil)
        #expect((descending.usedFraction ?? 1) < 0.1)
        let cycling = SequenceInfo(dataType: "integer", startValue: 1, increment: 1, minValue: 1, maxValue: 100, cache: 1, cycles: true,
                                   lastValue: 99, ownedBy: nil)
        #expect(!cycling.isNearlyExhausted)
        let fresh = SequenceInfo(dataType: "bigint", startValue: 1, increment: 1, minValue: 1, maxValue: Int64.max, cache: 1, cycles: false,
                                 lastValue: nil, ownedBy: nil)
        #expect(fresh.usedFraction == 0)
    }

    @Test func settingDisplayValues() {
        func setting(_ value: String, _ unit: String?) -> ServerSetting {
            ServerSetting(name: "x", setting: value, unit: unit, category: nil, description: nil, source: "configuration file", bootValue: nil,
                          resetValue: nil, context: nil, pendingRestart: false)
        }
        #expect(setting("4096", "8kB").displayValue == "32.0 MB")
        #expect(setting("64", "MB").displayValue == "64.0 MB")
        #expect(setting("200", "ms").displayValue == "200 ms")
        #expect(setting("on", nil).displayValue == "on")
        #expect(setting("99999999999999999999", "8kB").displayValue.hasSuffix("8kB"))
        #expect(setting("x", "8kB").isNonDefault)
    }
}

@Suite("Blocking tree")
struct BlockingTreeTests {
    func session(_ pid: Int32, blockedBy: [Int32] = [], xact: Double? = nil) -> ActivitySession {
        ActivitySession(pid: pid, state: "active", waitEventType: blockedBy.isEmpty ? nil : "Lock", transactionSeconds: xact, blockedBy: blockedBy)
    }

    @Test func buildsChains() {
        // A blocks B and C; C blocks D.
        let tree = BlockingTree.build([session(1), session(2, blockedBy: [1]), session(3, blockedBy: [1]), session(4, blockedBy: [3]), session(5)])
        #expect(tree.count == 1)
        #expect(tree[0].session.pid == 1)
        #expect(tree[0].waiters.map(\.session.pid) == [2, 3])
        #expect(tree[0].waiters[1].waiters.map(\.session.pid) == [4])
        #expect(tree[0].blockedCount == 3)
    }

    @Test func handlesCyclesAndMissingSessions() {
        let deadlock = BlockingTree.build([session(1, blockedBy: [2], xact: 10), session(2, blockedBy: [1], xact: 5)])
        #expect(!deadlock.isEmpty)
        #expect(deadlock[0].session.pid == 1)
        #expect(deadlock[0].blockedCount == 1)
        // Blocker not visible (other database / no privilege): nothing to anchor, nothing crashes.
        #expect(BlockingTree.build([session(3, blockedBy: [999])]).isEmpty)
        #expect(BlockingTree.build([]).isEmpty)
        // Self-reference is ignored.
        #expect(BlockingTree.build([session(1, blockedBy: [1])]).isEmpty)
    }

    @Test func boundedDepth() {
        var sessions = [session(0)]
        for pid in 1..<200 { sessions.append(session(Int32(pid), blockedBy: [Int32(pid - 1)])) }
        let tree = BlockingTree.build(sessions, maxDepth: 16)
        var depth = 0
        var node = tree.first
        while let current = node, let next = current.waiters.first { depth += 1; node = next }
        #expect(depth == 16)
    }
}

@Suite("Estimators and DDL")
struct EstimatorTests {
    let columns = [
        ColumnInfo(number: 1, name: "id", type: "bigint", isNullable: false, nullFraction: 0, averageWidth: 8),
        ColumnInfo(number: 2, name: "name", type: "text", isNullable: true, comment: "it's", nullFraction: 0.1, averageWidth: 20),
    ]

    @Test func tableBloat() throws {
        // 10,000 rows of ~56 bytes fit in ~70 pages; 500 pages means most of it is bloat.
        let estimate = try #require(BloatEstimator.table(pages: 500, tuples: 10_000, columns: columns, blockSize: 8192))
        #expect(estimate.ratio > 0.8)
        let tight = try #require(BloatEstimator.table(pages: 70, tuples: 10_000, columns: columns, blockSize: 8192))
        #expect(tight.ratio < 0.15)
        #expect(BloatEstimator.table(pages: 0, tuples: 0, columns: columns, blockSize: 8192) == nil)
        #expect(BloatEstimator.table(pages: 10, tuples: .nan, columns: columns, blockSize: 8192) == nil)
        #expect(BloatEstimator.table(pages: Int64.max, tuples: 1, columns: columns, blockSize: 8192) == nil)
        let unanalyzed = [ColumnInfo(number: 1, name: "id", type: "int", isNullable: false)]
        #expect(BloatEstimator.table(pages: 10, tuples: 10, columns: unanalyzed, blockSize: 8192) == nil)
    }

    @Test func indexBloat() {
        let index = IndexInfo(oid: 1, name: "i", definition: "", method: "btree", isUnique: false, isPrimary: false, columnNumbers: [1],
                              estimatedTuples: 10_000, pages: 400)
        #expect((BloatEstimator.btreeIndex(index, columns: columns, blockSize: 8192)?.ratio ?? 0) > 0.8)
        let expression = IndexInfo(oid: 2, name: "e", definition: "", method: "btree", isUnique: false, isPrimary: false, columnNumbers: [0],
                                   estimatedTuples: 10, pages: 10)
        #expect(BloatEstimator.btreeIndex(expression, columns: columns, blockSize: 8192) == nil)
        let gin = IndexInfo(oid: 3, name: "g", definition: "", method: "gin", isUnique: false, isPrimary: false, columnNumbers: [2],
                            estimatedTuples: 10, pages: 10)
        #expect(BloatEstimator.btreeIndex(gin, columns: columns, blockSize: 8192) == nil)
    }

    @Test func tableDDL() {
        let relation = RelationSummary(oid: 1, schema: "app", name: "Users", kind: .table, comment: "People")
        let ddl = DDLBuilder.table(relation, columns: columns + [
            ColumnInfo(number: 3, name: "total", type: "numeric", isNullable: true, generatedExpression: "price * 2"),
            ColumnInfo(number: 4, name: "n", type: "integer", isNullable: false, identity: "a"),
            ColumnInfo(number: 5, name: "inherited", type: "integer", isNullable: true, isLocal: false),
        ], constraints: [
            ConstraintInfo(name: "users_pkey", kind: .primaryKey, definition: "PRIMARY KEY (id)"),
            ConstraintInfo(name: "users_id_not_null", kind: .notNull, definition: "NOT NULL id"),
            ConstraintInfo(name: "parent_check", kind: .check, definition: "CHECK (id > 0)", isLocal: false),
        ], indexes: [
            IndexInfo(oid: 9, name: "users_pkey", definition: "CREATE UNIQUE INDEX users_pkey ON app.\"Users\" USING btree (id)", method: "btree",
                      isUnique: true, isPrimary: true, constraintName: "users_pkey"),
            IndexInfo(oid: 10, name: "users_name", definition: "CREATE INDEX users_name ON app.\"Users\" USING btree (name)", method: "btree",
                      isUnique: false, isPrimary: false),
        ], triggers: [], partitioning: PartitioningInfo(partitionKey: "RANGE (id)", parent: nil, children: []), options: ["fillfactor=90"])
        #expect(ddl.contains("CREATE TABLE app.\"Users\" (\n    id bigint NOT NULL,\n    name text,"))
        #expect(ddl.contains("total numeric GENERATED ALWAYS AS (price * 2) STORED"))
        #expect(ddl.contains("n integer GENERATED ALWAYS AS IDENTITY NOT NULL"))
        #expect(!ddl.contains("inherited integer"))
        #expect(ddl.contains("CONSTRAINT users_pkey PRIMARY KEY (id)"))
        #expect(!ddl.contains("NOT NULL id"))
        #expect(!ddl.contains("parent_check"))
        #expect(ddl.contains("PARTITION BY RANGE (id)\nWITH (fillfactor=90);"))
        #expect(ddl.contains("CREATE INDEX users_name ON app.\"Users\" USING btree (name);"))
        #expect(!ddl.contains("CREATE UNIQUE INDEX users_pkey"))
        #expect(ddl.contains("COMMENT ON TABLE app.\"Users\" IS 'People';"))
        #expect(ddl.contains("COMMENT ON COLUMN app.\"Users\".name IS 'it''s';"))
    }

    @Test func partitionAndViewDDL() {
        let partition = RelationSummary(oid: 2, schema: "app", name: "m_2026", kind: .table, isPartition: true,
                                        partitionBound: "FOR VALUES FROM ('2026-01-01') TO ('2027-01-01')", parentOID: 1)
        let ddl = DDLBuilder.table(partition, columns: columns, constraints: [], indexes: [], triggers: [],
                                   partitioning: PartitioningInfo(partitionKey: nil, parent: "app.m", children: []), options: [])
        #expect(ddl.hasPrefix("CREATE TABLE app.m_2026 PARTITION OF app.m\n    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');"))
        let view = RelationSummary(oid: 3, schema: "app", name: "v", kind: .materializedView)
        let mv = DDLBuilder.view(view, definition: " SELECT 1 AS x;", indexes: [])
        #expect(mv.hasPrefix("CREATE MATERIALIZED VIEW app.v AS\nSELECT 1 AS x\nWITH DATA;"))
    }

    @Test func quoting() {
        #expect(SQLText.identifier("users") == "users")
        #expect(SQLText.identifier("Users") == "\"Users\"")
        #expect(SQLText.identifier("order") == "\"order\"")
        #expect(SQLText.identifier("a\"b") == "\"a\"\"b\"")
        #expect(SQLText.identifier("1abc") == "\"1abc\"")
        #expect(SQLText.literal("it's\0") == "'it''s'")
        #expect(SQLText.qualified("public", "t") == "public.t")
    }
}
