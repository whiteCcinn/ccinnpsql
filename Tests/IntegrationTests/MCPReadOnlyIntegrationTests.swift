import Foundation
@testable import CcinnPsqlKit
import PostgresKit
import PostgresWire
import Testing

/// The MCP read-only path as a superuser on a real server: every escape hatch that a READ ONLY transaction does not
/// block must be refused, and nothing may happen on the server (design D14).
@Suite("MCP read-only enforcement", .enabled(if: IT.enabled), .serialized)
struct MCPReadOnlyIntegrationTests {
    static let attempts: [String] = [
        "COPY (SELECT 1) TO PROGRAM 'touch /tmp/ccinnpsql_mcp_pwned'",
        "COPY (SELECT 1) TO '/tmp/ccinnpsql_mcp_pwned'",
        "DO $$ BEGIN PERFORM pg_reload_conf(); END $$",
        "NOTIFY ccinnpsql_mcp_it, 'leak'",
        "SELECT pg_notify('ccinnpsql_mcp_it', 'leak')",
        "SELECT pg_reload_conf()",
        "SELECT pg_catalog.pg_reload_conf()",
        "SELECT \"pg_reload_conf\"()",
        "SELECT pg_rotate_logfile()",
        "SELECT pg_switch_wal()",
        "SELECT pg_create_restore_point('ccinnpsql_mcp')",
        "SELECT pg_logical_emit_message(true, 'ccinnpsql', 'x')",
        "SELECT pg_create_logical_replication_slot('ccinnpsql_mcp_slot', 'test_decoding')",
        "SELECT * FROM pg_create_physical_replication_slot('ccinnpsql_mcp_phys')",
        "SELECT pg_drop_replication_slot('anything')",
        "SELECT pg_replication_origin_create('ccinnpsql_mcp_origin')",
        "SELECT pg_stat_reset()",
        "SELECT pg_stat_statements_reset()",
        "SELECT pg_promote()",
        "SELECT pg_wal_replay_pause()",
        "SELECT lo_import('/etc/hostname')",
        "SELECT lo_export(1, '/tmp/ccinnpsql_mcp_pwned')",
        "SELECT lo_unlink(1)",
        "SELECT pg_read_file('/etc/hostname')",
        "SELECT pg_read_binary_file('/etc/hostname')",
        "SELECT pg_ls_dir('.')",
        "SELECT U&\"pg\\005fread_file\"('/etc/hostname')",
        "SELECT set_config('default_transaction_read_only', 'off', false)",
        "BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT s", "RELEASE s", "PREPARE TRANSACTION 'x'",
        "SET TRANSACTION READ WRITE", "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE", "SET default_transaction_read_only = off",
        "WITH d AS (DELETE FROM ccinnpsql_mcp_probe RETURNING *) SELECT * FROM d",
        "SELECT * INTO ccinnpsql_mcp_created FROM ccinnpsql_mcp_probe",
        "SELECT * FROM ccinnpsql_mcp_probe FOR UPDATE",
        "SELECT 1; DELETE FROM ccinnpsql_mcp_probe",
        "EXPLAIN ANALYZE DELETE FROM ccinnpsql_mcp_probe",
        // Review finding 1: functions that run SQL passed as text.
        "SELECT * FROM ts_stat($q$SELECT to_tsvector(pg_advisory_lock(424243)::text)$q$)",
        "SELECT ts_rewrite('a'::tsquery, 'SELECT ''a''::tsquery, ''b''::tsquery')",
        "SELECT query_to_xml('SELECT pg_advisory_lock(424243)', true, false, '')",
    ]

    @Test(arguments: IT.versions)
    func everyEscapeIsRefusedAndNothingHappens(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        _ = try await client.simpleQuery("""
            DROP TABLE IF EXISTS ccinnpsql_mcp_probe, ccinnpsql_mcp_created;
            CREATE TABLE ccinnpsql_mcp_probe (id int);
            INSERT INTO ccinnpsql_mcp_probe VALUES (1);
            CREATE OR REPLACE FUNCTION ccinnpsql_mcp_writer() RETURNS int LANGUAGE sql AS $$ INSERT INTO ccinnpsql_mcp_probe VALUES (2) RETURNING 2 $$;
            """)
        let listener = try await PostgresListener.open(client: client)
        try await listener.listen("ccinnpsql_mcp_it")

        let profile = ConnectionProfile(name: "IT \(version)", host: "127.0.0.1", port: IT.port(version), username: "ccinn", database: "ccinn",
                                        mcpAccess: .readOnly)
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in client }, audit: nil)

        for sql in Self.attempts {
            let result = await tools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(result.isError, "accepted: \(sql)")
        }
        // Passes the lexical guard, refused by the server's READ ONLY transaction.
        let writer = await tools.call(name: "run_query", arguments: ["sql": "SELECT ccinnpsql_mcp_writer()"])
        #expect(writer.isError)
        #expect(writer.payload.stringValue?.contains("25006") == true || writer.payload.stringValue?.contains("read-only") == true)
        // Reads still work.
        let read = await tools.call(name: "run_query", arguments: ["sql": "SELECT count(*) AS n FROM ccinnpsql_mcp_probe"])
        #expect(!read.isError)
        #expect(read.payload["rows"]?[0]?[0] == .int(1))

        // Nothing happened on the server.
        #expect(try await client.records("SELECT count(*) AS n FROM ccinnpsql_mcp_probe").first?.int("n") == 1)
        #expect(try await client.records("SELECT to_regclass('ccinnpsql_mcp_created') IS NULL AS absent").first?.bool("absent") == true)
        #expect(try await client.records("SELECT count(*) AS n FROM pg_replication_slots WHERE slot_name LIKE 'ccinnpsql_mcp%'").first?.int("n") == 0)
        if client.serverInfo.version.atLeast(10) {
            #expect(try await client.records("SELECT count(*) AS n FROM pg_replication_origin WHERE roname LIKE 'ccinnpsql_mcp%'").first?.int("n") == 0)
        }
        if client.serverInfo.version.atLeast(11) {
            // Absolute paths in pg_stat_file need PostgreSQL 11+.
            let file = try await client.records("SELECT pg_stat_file('/tmp/ccinnpsql_mcp_pwned', true) IS NULL AS absent").first?.bool("absent")
            #expect(file == true, "a server-side file was written")
        }
        let notification = await withTaskGroup(of: NotificationMessage?.self) { group in
            group.addTask {
                var iterator = listener.notifications.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(600))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(notification == nil, "a notification was delivered")
        listener.close()
        // Pool connections used by the MCP tools are back to idle (the runner always ends with ROLLBACK).
        for _ in 0..<4 {
            let status = try await client.withConnection { await $0.transactionStatus }
            #expect(status == .idle)
        }
        _ = try await client.simpleQuery("DROP TABLE ccinnpsql_mcp_probe; DROP FUNCTION ccinnpsql_mcp_writer()")
    }

    /// Review findings 1–3: SQL hidden in text cannot signal other backends, a session advisory lock taken by a
    /// function the guard cannot see into is released before the connection returns to the pool, string
    /// literals are lexed by the server exactly as the guard lexes them, and a query in another database whose
    /// column types need a `pg_type` lookup does not wait for a second connection of a one-connection pool.
    @Test(arguments: IT.versions)
    func hiddenSideEffectsStringRulesAndOtherDatabases(version: String) async throws {
        let admin = try await IT.client(version)
        defer { Task { await admin.close() } }
        let scram = admin.serverInfo.version.atLeast(10) ? "SET password_encryption = 'scram-sha-256'; " : ""
        _ = try await admin.simpleQuery("""
            DROP ROLE IF EXISTS ccinnpsql_scs_off;
            \(scram)CREATE ROLE ccinnpsql_scs_off LOGIN PASSWORD 'scsoff';
            ALTER ROLE ccinnpsql_scs_off SET standard_conforming_strings = off;
            CREATE OR REPLACE FUNCTION ccinnpsql_mcp_locker() RETURNS int LANGUAGE plpgsql AS $f$ BEGIN PERFORM pg_advisory_lock(424242); RETURN 1; END $f$;
            """)
        let victim = try await IT.connect(version)
        let victimPID = try #require(victim.backendKey?.processID)

        // The MCP server's pool size: pools for other databases get a single connection.
        let mcpClient = try await PostgresClient.connect(IT.configuration(version), poolSize: 3)
        let profile = ConnectionProfile(name: "IT \(version)", host: "127.0.0.1", port: IT.port(version), username: "ccinn", database: "ccinn",
                                        mcpAccess: .readOnly)
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in mcpClient }, audit: nil)

        let terminate = await tools.call(name: "run_query", arguments: [
            "sql": .string("SELECT * FROM ts_stat($q$SELECT to_tsvector(pg_terminate_backend(\(victimPID))::text)$q$)"),
        ])
        #expect(terminate.isError)
        #expect(try await victim.simpleQuery("SELECT 1 AS alive").lastRowSet?.scalar == "1", "the victim backend was terminated")

        let locker = await tools.call(name: "run_query", arguments: ["sql": "SELECT ccinnpsql_mcp_locker() AS locked"])
        #expect(!locker.isError, "\(locker.payload)")
        let held = try await admin.records("SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory' AND objid IN (424242, 424243, 777)")
        #expect(held.first?.int("n") == 0, "an advisory lock survived the read-only run")

        let other = await tools.call(name: "run_query", arguments: [
            "sql": "SELECT indkey, indclass FROM pg_index LIMIT 1", "database": "postgres", "timeout_seconds": 20,
        ])
        #expect(!other.isError, "\(other.payload)")
        #expect(other.payload["columns"]?[0]?["type"] == "int2vector")
        #expect(other.payload["columns"]?[1]?["type"] == "oidvector")

        // standard_conforming_strings = off for this role: the MCP transaction pins it on.
        var offConfiguration = IT.configuration(version, user: "ccinnpsql_scs_off", password: "scsoff")
        offConfiguration.database = "ccinn"
        let offClient = try await PostgresClient.connect(offConfiguration, poolSize: 3)
        #expect(try await offClient.records("SELECT current_setting('standard_conforming_strings') AS scs").first?.text("scs") == "off")
        let offProfile = ConnectionProfile(name: "IT scs off \(version)", host: "127.0.0.1", port: IT.port(version), username: "ccinnpsql_scs_off",
                                           database: "ccinn", mcpAccess: .readOnly)
        let offTools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [offProfile], defaultProfile: nil, forceReadOnly: false),
                                        registry: MCPClientRegistry { _ in offClient }, audit: nil)
        let pinned = await offTools.call(name: "run_query", arguments: ["sql": "SELECT current_setting('standard_conforming_strings') AS scs"])
        #expect(pinned.payload["rows"]?[0]?[0] == "on", "\(pinned.payload)")
        let smuggled = await offTools.call(name: "run_query", arguments: ["sql": .string("SELECT '\\'' , pg_advisory_lock(777) , '\\''")])
        #expect(smuggled.isError)
        let backslash = await offTools.call(name: "run_query", arguments: ["sql": .string("SELECT 'a\\b' AS text")])
        #expect(backslash.payload["rows"]?[0]?[0] == .string("a\\b"), "\(backslash.payload)")
        #expect(try await admin.records("SELECT count(*) AS n FROM pg_locks WHERE locktype = 'advisory' AND objid = 777").first?.int("n") == 0)

        await offClient.close()
        await mcpClient.close()
        await victim.close()
        _ = try await admin.simpleQuery("DROP FUNCTION ccinnpsql_mcp_locker(); DROP ROLE ccinnpsql_scs_off")
    }
}
