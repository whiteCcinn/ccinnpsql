import CcinnPsqlKit
import Foundation
import PostgresKit
import Testing

/// Real PostgreSQL errors are located on the text the user wrote.
@Suite("Error diagnostics integration", .enabled(if: IT.enabled), .serialized)
struct DiagnosticsIntegrationTests {
    /// (text as written and sent, protocol, text expected to be marked — nil when nothing in the text is to blame)
    static let cases: [(String, ExecutionMode, String?)] = [
        ("SELECT 1 FORM shop.orders", .extended, "shop"),
        ("SELECT '🇲🇾', 1 FORM shop.orders", .extended, "shop"),
        ("SELECT nme FROM shop.customers t", .extended, "nme"),
        ("SELECT t.nme FROM shop.customers t", .extended, "t.nme"),
        ("SELECT * FROM shop.nosuch_table", .extended, "shop.nosuch_table"),
        ("SELECT * FROM Shop.Nosuch", .extended, "Shop.Nosuch"),
        ("SELECT * FROM \"Orders\"", .extended, "\"Orders\""),
        ("SELECT abs(1,2,3)", .extended, "abs(1,2,3)"),
        ("SELECT * FROM shop.orders WHERE", .extended, "WHERE"),
        ("SELECT 'abc", .extended, "'"),
        ("SELECT E'a\\'", .extended, "E'"),
        ("SELECT 1 /* a /* b */", .extended, "/*"),
        ("SELECT $$abc", .extended, "$$"),
        ("SELECT 1::nosuchtype", .extended, "nosuchtype"),
        ("SELECT '1'::int + 'x'::int", .extended, "'x'"),
        ("SELECT\n  id,\n  nme\nFROM shop.customers", .extended, "nme"),
        ("UPDATE shop.orders SET nosuchcol = 1", .extended, "nosuchcol"),
        ("DROP TABLE nosuch_x", .extended, "nosuch_x"),
        ("CREATE TABLE shop.orders (id int)", .extended, "orders"),
        ("INSERT INTO shop.customers (id) VALUES (1)", .extended, "shop.customers"),
        ("CREATE OR REPLACE FUNCTION public.ccinnpsql_it_bad() RETURNS int LANGUAGE sql AS $$ SELECT nosuch FROM shop.orders $$", .extended, "nosuch"),
        ("DO $$\nBEGIN\n  EXECUTE 'SELECT nosuchcol FROM shop.orders';\nEND\n$$", .extended, "nosuchcol"),
        ("DO $$\nBEGIN\n  EXECUTE 'SELECT ''a'' || nosuchcol FROM shop.orders';\nEND\n$$", .extended, "nosuchcol"),
        ("DO $$\nBEGIN\n  PERFORM * FROM nosuch_in_do;\nEND\n$$", .extended, "nosuch_in_do"),
        ("DO $$\nBEGIN\n  INSERT INTO nosuch_ins VALUES (1);\nEND\n$$", .extended, "nosuch_ins"),
        ("DO $do$\nBEGIN\n  RAISE EXCEPTION 'boom %', 1 USING HINT = 'try again';\nEND\n$do$", .extended,
         "RAISE EXCEPTION 'boom %', 1 USING HINT = 'try again';"),
        ("SELECT 1/0", .extended, nil),
        // A simple-protocol script: positions count from the start of the whole script.
        ("SELECT 1; SELECT nosuch FROM shop.orders; SELECT 2", .simple, "nosuch"),
        ("SELECT 1;\nSELECT 2 FORM t", .simple, "t"),
    ]

    private func failure(_ client: PostgresClient, _ sql: String, mode: ExecutionMode = .extended) async -> (any Error)? {
        let session = client.openSession()
        defer { Task { await session.close() } }
        do {
            _ = try await session.run(sql, mode: mode)
            return nil
        } catch {
            return error
        }
    }

    private func marked(_ text: String, _ range: Range<Int>?) -> String? {
        guard let range else { return nil }
        return String(decoding: Array(text.utf16)[range], as: UTF16.self)
    }

    @Test(arguments: IT.versions)
    func locatesRealErrors(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        for (sql, mode, expected) in Self.cases {
            let error = try #require(await failure(client, sql, mode: mode), "\(sql) should fail")
            let parsed = SQLServerError(error)
            #expect(parsed.sqlState != nil, "\(sql): \(parsed.message)")
            #expect(marked(sql, SQLErrorLocator.range(in: sql, error: parsed)) == expected, "\(sql.prefix(60)) → \(parsed.message)")
        }
        await client.close()
    }

    @Test(arguments: IT.versions)
    func runtimeErrorsInDoBlocksMarkTheirStatement(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let sql = "DO $$\nDECLARE x int;\nBEGIN\n  x := 1/0;\nEND\n$$"
        let error = SQLServerError(try #require(await failure(client, sql)))
        // PostgreSQL 14+ quotes the assignment in the context; older versions only name the body line.
        let major = Int(version.split(separator: ".").first ?? "") ?? 17
        #expect(marked(sql, SQLErrorLocator.range(in: sql, error: error)) == (major >= 14 ? "x := 1/0" : "x := 1/0;"), "\(error.context ?? "")")
        await client.close()
    }

    @Test(arguments: IT.versions)
    func scriptErrorsWithoutAPositionMarkTheFailingStatement(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let script = "SELECT 'x' AS nosuch_x; DROP TABLE nosuch_x; SELECT 2"
        let error = try #require(await failure(client, script, mode: .simple))
        let completed = try #require(error as? PostgresError).completedStatements
        #expect(completed == 1)
        let found = try #require(SQLErrorLocator.scriptRange(in: script, error: SQLServerError(error), completedStatements: completed))
        #expect(marked(script, found.statement) == "DROP TABLE nosuch_x")
        #expect(found.range.lowerBound == (script as NSString).range(of: "nosuch_x; SELECT 2").location)
        await client.close()
    }

    @Test(arguments: IT.versions)
    func hintsAndPositionsComeFromTheServer(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let error = SQLServerError(try #require(await failure(client, "SELECT nme FROM shop.customers t")))
        #expect(error.position == 8)
        #expect(error.conditionName == "undefined_column")
        #expect(error.hint?.contains("\"t.name\"") == true)
        #expect(error.diagnosticMessage.contains("HINT: Perhaps you meant to reference the column \"t.name\""))
        await client.close()
    }

    @Test(arguments: IT.versions)
    func mapsExplainAndAutoLimitBack(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let source = "SELECT 1 FORM shop.orders"
        let explain = ExplainPlan.statement(for: source, analyze: false, buffers: false)
        let explained = SQLServerError(try #require(await failure(client, explain)))
        let mapping = SQLExecutedTextMapping(prefixLength: ExplainPlan.statementPrefix(analyze: false, buffers: false).utf16.count)
        #expect(marked(source, SQLErrorLocator.range(in: source, executed: explain, mapping: mapping, error: explained)) == "shop")

        // The LIMIT lands right after WHERE, where the server reports the error.
        let unfinished = "SELECT * FROM shop.orders WHERE -- todo"
        let limited = AutoLimit.apply(to: unfinished, limit: 1000)
        let message = SQLServerError(try #require(await failure(client, limited.sql)))
        #expect(marked(unfinished, SQLErrorLocator.range(in: unfinished, executed: limited.sql,
                                                         mapping: SQLExecutedTextMapping(insertion: limited.insertion), error: message)) == "WHERE")
        await client.close()
    }

    @Test(arguments: IT.versions)
    func clientSideChecksAgreeWithTheServer(version: String) async throws {
        // What the local check flags, PostgreSQL rejects at the same place.
        let client = try await PostgresClient.connect(IT.configuration(version))
        for sql in ["SELECT 'abc", "SELECT \"abc", "SELECT $fn$ abc", "SELECT 1 /* a /* b */", "SELECT E'a\\'", "SELECT count(1 FROM shop.orders"] {
            let local = try #require(SQLLinter.diagnose(sql).first, "\(sql)")
            let server = SQLServerError(try #require(await failure(client, sql), "\(sql)"))
            let located = try #require(SQLErrorLocator.range(in: sql, error: server), "\(sql)")
            #expect(server.sqlState == "42601", "\(sql): \(server.message)")
            if sql.contains("count(") {
                // The server sees the missing `)` at the end of input; the local check marks the `(` itself.
                #expect(local.range.lowerBound < located.lowerBound)
            } else {
                #expect(local.range == located, "\(sql): \(server.message)")
            }
        }
        await client.close()
    }
}
