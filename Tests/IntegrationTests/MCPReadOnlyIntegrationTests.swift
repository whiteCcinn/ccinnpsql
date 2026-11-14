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
}
