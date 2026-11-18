import Foundation
@testable import CcinnPsqlKit
import PostgresKit
import PostgresWire
import Testing

/// The read-only MCP role check on real servers: privileged roles (reached through any chain of memberships) are refused
/// unless the connection allows them, a plain role is allowed, and on a plain role the server itself refuses the
/// COPY … TO PROGRAM that a text guard cannot see (built at run time). Temporary `zz_` roles are created and dropped.
@Suite("MCP role check", .enabled(if: IT.enabled), .serialized)
struct MCPRoleIntegrationTests {
    private static let password = "zzpass"

    private func major(_ client: PostgresClient) -> Int { client.serverInfo.version.major }

    private func roles(_ admin: PostgresClient) -> [String] {
        var roles = ["zz_mcp_super", "zz_mcp_plain", "zz_mcp_member", "zz_mcp_noinherit", "zz_mcp_alt", "zz_mcp_enc", "zz_mcp_monitor",
                     "zz_mcp_stats", "zz_mcp_settings", "zz_mcp_path"]
        if major(admin) >= 11 { roles += ["zz_mcp_prog", "zz_mcp_read", "zz_mcp_write", "zz_mcp_mid", "zz_mcp_chain"] }
        if major(admin) >= 16 { roles += ["zz_mcp_setonly", "zz_mcp_neither"] }
        return roles
    }

    /// Databases in single-byte encodings (C locale, which the alpine containers have; the Turkish-locale fold itself is
    /// verified on a glibc server outside this suite).
    private static let singleByteDatabases = [("zz_mcp_latin1", "LATIN1"), ("zz_mcp_ascii", "SQL_ASCII")]

    private func setUp(_ admin: PostgresClient) async throws {
        try await tearDown(admin)
        for (name, encoding) in Self.singleByteDatabases {
            _ = try await admin.simpleQuery("CREATE DATABASE \(name) ENCODING '\(encoding)' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0")
        }
        let scram = major(admin) >= 10 ? "SET password_encryption = 'scram-sha-256'; " : ""
        var sql = scram
        for role in roles(admin) where role != "zz_mcp_mid" && role != "zz_mcp_super" {
            sql += "CREATE ROLE \(role) LOGIN PASSWORD '\(Self.password)'; "
        }
        sql += "CREATE ROLE zz_mcp_super SUPERUSER NOLOGIN; "
        sql += """
            ALTER ROLE zz_mcp_noinherit NOINHERIT;
            GRANT zz_mcp_super TO zz_mcp_member; GRANT zz_mcp_super TO zz_mcp_noinherit;
            GRANT zz_mcp_member TO zz_mcp_alt; ALTER ROLE zz_mcp_alt SET role = 'zz_mcp_member';
            ALTER ROLE zz_mcp_enc SET client_encoding = 'SJIS';
            GRANT pg_monitor TO zz_mcp_monitor; GRANT pg_read_all_stats TO zz_mcp_stats; GRANT pg_read_all_settings TO zz_mcp_settings;
            CREATE FOREIGN DATA WRAPPER zz_mcp_fdw; CREATE SERVER zz_mcp_srv FOREIGN DATA WRAPPER zz_mcp_fdw;
            GRANT USAGE ON FOREIGN SERVER zz_mcp_srv TO zz_mcp_plain;
            CREATE USER MAPPING FOR zz_mcp_plain SERVER zz_mcp_srv OPTIONS (password 'zz-map-secret');
            CREATE OR REPLACE FUNCTION public.zz_mcp_exec(q text) RETURNS int LANGUAGE plpgsql AS $f$ BEGIN EXECUTE q; RETURN 1; END $f$;
            CREATE OR REPLACE FUNCTION public.zz_mcp_secdef() RETURNS int SECURITY DEFINER LANGUAGE sql AS 'SELECT 1';
            CREATE EXTENSION file_fdw; CREATE SERVER zz_mcp_files FOREIGN DATA WRAPPER file_fdw;
            CREATE FOREIGN TABLE public.zz_mcp_prog_t (line text) SERVER zz_mcp_files OPTIONS (program 'echo zz-program-ran');
            CREATE FOREIGN TABLE public.zz_mcp_file_t (line text) SERVER zz_mcp_files OPTIONS (filename '/etc/hostname');
            CREATE FOREIGN TABLE public.zz_mcp_col_t (line text) SERVER zz_mcp_files OPTIONS (program 'echo zz-column-grant');
            CREATE FOREIGN TABLE public.zz_mcp_hidden_t (line text) SERVER zz_mcp_files OPTIONS (program 'echo zz-hidden');
            GRANT SELECT ON public.zz_mcp_prog_t, public.zz_mcp_file_t TO zz_mcp_plain; GRANT SELECT (line) ON public.zz_mcp_col_t TO zz_mcp_plain;
            CREATE TABLE public.zz_mcp_brin (a int, t tsvector); CREATE INDEX zz_mcp_brin_i ON public.zz_mcp_brin USING brin (a);
            CREATE INDEX zz_mcp_gin_i ON public.zz_mcp_brin USING gin (t) WITH (fastupdate = on); ALTER TABLE public.zz_mcp_brin OWNER TO zz_mcp_plain;
            ALTER ROLE zz_mcp_plain SET zz_mcp.api_key = 'zz-role-secret'; ALTER DATABASE ccinn SET zz_mcp.jwt_secret = 'zz-db-secret';
            CREATE SCHEMA dbms_sql; CREATE FUNCTION dbms_sql.open_cursor() RETURNS int LANGUAGE sql AS 'SELECT 7';
            GRANT USAGE ON SCHEMA dbms_sql TO zz_mcp_path; ALTER ROLE zz_mcp_path SET search_path = public, dbms_sql;
            CREATE FUNCTION public.zz_mcp_peek(text) RETURNS text LANGUAGE internal AS 'pg_read_file_all';
            CREATE FUNCTION public.zz_mcp_dir(text) RETURNS SETOF text LANGUAGE internal AS 'pg_ls_dir_1arg';
            CREATE VIEW public.zz_mcp_peek_v AS SELECT public.zz_mcp_peek('PG_VERSION') AS v; GRANT SELECT ON public.zz_mcp_peek_v TO zz_mcp_plain;
            CREATE TYPE public.zz_mcp_range AS RANGE (subtype = float8); CREATE AGGREGATE public.zz_mcp_sum(int) (sfunc = int4pl, stype = int);
            CREATE EXTENSION postgres_fdw; CREATE SERVER zz_mcp_remote FOREIGN DATA WRAPPER postgres_fdw OPTIONS (dbname 'ccinn');
            CREATE FOREIGN TABLE public.zz_mcp_remote_t (a int) SERVER zz_mcp_remote; GRANT SELECT ON public.zz_mcp_remote_t TO zz_mcp_plain;
            """
        if major(admin) >= 11 {
            sql += """
                CREATE ROLE zz_mcp_mid NOLOGIN; ALTER ROLE zz_mcp_chain NOINHERIT;
                GRANT pg_execute_server_program TO zz_mcp_prog; GRANT pg_read_server_files TO zz_mcp_read;
                GRANT pg_write_server_files TO zz_mcp_write; GRANT pg_read_server_files TO zz_mcp_mid; GRANT zz_mcp_mid TO zz_mcp_chain;
                CREATE OR REPLACE PROCEDURE public.zz_mcp_secdef_proc() SECURITY DEFINER LANGUAGE sql AS $p$ SELECT 1 $p$;
                """
        }
        if major(admin) >= 16 {
            sql += "GRANT zz_mcp_super TO zz_mcp_setonly WITH INHERIT FALSE, SET TRUE; GRANT zz_mcp_super TO zz_mcp_neither WITH INHERIT FALSE, SET FALSE;"
        }
        _ = try await admin.simpleQuery(sql)
    }

    /// Removes everything the suite creates, and sweeps every `zz_mcp_*` database and role, also those an interrupted or
    /// failed earlier run left behind (run before setUp and after every run, failed or not).
    private func tearDown(_ admin: PostgresClient) async throws {
        let databases = try await admin.records("SELECT datname FROM pg_catalog.pg_database WHERE datname LIKE 'zz\\_mcp\\_%' ORDER BY 1")
            .compactMap { $0.text("datname") }
        for name in databases { _ = try await admin.simpleQuery("DROP DATABASE IF EXISTS \(SQLText.quoteIdentifier(name)) WITH (FORCE)") }
        var sql = "DROP FUNCTION IF EXISTS public.zz_mcp_exec(text), public.zz_mcp_secdef(); DROP TABLE IF EXISTS public.zz_mcp_nul_t; "
            + "DROP FOREIGN DATA WRAPPER IF EXISTS zz_mcp_fdw CASCADE; DROP EXTENSION IF EXISTS file_fdw CASCADE; DROP TABLE IF EXISTS public.zz_mcp_brin; "
            + "DROP SCHEMA IF EXISTS dbms_sql CASCADE; ALTER DATABASE ccinn RESET zz_mcp.jwt_secret; DROP VIEW IF EXISTS public.zz_mcp_peek_v; "
            + "DROP FUNCTION IF EXISTS public.zz_mcp_peek(text), public.zz_mcp_dir(text); DROP AGGREGATE IF EXISTS public.zz_mcp_sum(int); "
            + "DROP TYPE IF EXISTS public.zz_mcp_range; DROP EXTENSION IF EXISTS postgres_fdw CASCADE; "
        if major(admin) >= 11 { sql += "DROP PROCEDURE IF EXISTS public.zz_mcp_secdef_proc(); " }
        _ = try await admin.simpleQuery(sql)
        let leftover = try await admin.records("SELECT rolname FROM pg_catalog.pg_roles WHERE rolname LIKE 'zz\\_mcp\\_%' ORDER BY 1")
            .compactMap { $0.text("rolname") }
        guard !leftover.isEmpty else { return }
        let names = leftover.map(SQLText.quoteIdentifier)
        // Objects and grants the test roles still hold (from any run) are dropped with them, then every role in one statement.
        _ = try await admin.simpleQuery("DROP OWNED BY \(names.joined(separator: ", ")); DROP ROLE IF EXISTS \(names.joined(separator: ", "));")
    }

    private func tools(_ client: PostgresClient, user: String, allowPrivileged: Bool = false) -> PostgresMCPTools {
        let profile = ConnectionProfile(name: user, host: "127.0.0.1", port: client.configuration.endpoint.port, username: user, database: "ccinn",
                                        mcpAccess: .readOnly, mcpAllowPrivilegedRole: allowPrivileged)
        return PostgresMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                registry: MCPClientRegistry { _ in client }, audit: nil)
    }

    private func connect(_ version: String, user: String) async throws -> PostgresClient {
        try await PostgresClient.connect(IT.configuration(version, user: user, password: Self.password), poolSize: 2)
    }

    private static let refusal = "This connection's role can run server programs, touch server files or read every session's SQL and settings"

    @Test(arguments: IT.versions)
    func privilegedRolesAreRefusedAndPlainRolesAllowed(version: String) async throws {
        let admin = try await PostgresClient.connect(IT.configuration(version))
        do {
            try await setUp(admin)
            try await checkRoles(version, admin)
        } catch {
            Issue.record("PostgreSQL \(version): \(error)")
        }
        // Always, whatever failed above (a failed setUp included): nothing of the suite stays on the server.
        do {
            try await tearDown(admin)
            let left = try await admin.records("""
                SELECT (SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname LIKE 'zz\\_mcp\\_%')
                     + (SELECT count(*) FROM pg_catalog.pg_database WHERE datname LIKE 'zz\\_mcp\\_%') AS n
                """).first?.int("n")
            #expect(left == 0, "PostgreSQL \(version): \(left ?? -1) zz_mcp_ roles or databases left")
        } catch {
            Issue.record("PostgreSQL \(version) cleanup: \(error)")
        }
        await admin.close()
    }

    private func checkRoles(_ version: String, _ admin: PostgresClient) async throws {
        // The superuser test connection: refused by default on every tool, allowed (with a notice) when opted in.
        let superTools = tools(admin, user: "ccinn")
        for (tool, arguments) in [("run_query", ["sql": JSONValue.string("SELECT 1")]), ("list_schemas", [:]), ("explain_query", ["sql": "SELECT 1"]),
                                  ("server_info", [:]), ("get_activity", [:]), ("get_settings", [:]), ("list_roles", [:])] {
            let refused = await superTools.call(name: tool, arguments: arguments)
            #expect(refused.isError && refused.payload.stringValue?.contains(Self.refusal) == true, "PostgreSQL \(version) \(tool): \(refused.payload)")
            // A refusal carries the check's notices too.
            #expect(refused.payload.stringValue?.contains("security_notices:\n- ") == true && refused.payload.stringValue?.contains("zz_mcp_secdef()") == true,
                    "PostgreSQL \(version) \(tool): \(refused.payload)")
        }
        let allowed = await tools(admin, user: "ccinn", allowPrivileged: true).call(name: "run_query", arguments: ["sql": "SELECT 1 AS one"])
        #expect(!allowed.isError, "\(allowed.payload)")
        #expect(allowed.payload["security_notices"]?.arrayValue?.contains { $0.stringValue?.contains("allowed for this connection") == true } == true)

        // Every way to reach a privileged role counts, INHERIT and SET ignored; current_user and session_user both.
        var privileged = ["zz_mcp_member", "zz_mcp_noinherit", "zz_mcp_alt", "zz_mcp_monitor", "zz_mcp_stats", "zz_mcp_settings"]
        if major(admin) >= 11 { privileged += ["zz_mcp_prog", "zz_mcp_read", "zz_mcp_write", "zz_mcp_chain"] }
        if major(admin) >= 16 { privileged += ["zz_mcp_setonly", "zz_mcp_neither"] }
        for user in privileged {
            let client = try await connect(version, user: user)
            let result = await tools(client, user: user).call(name: "run_query", arguments: ["sql": "SELECT 1"])
            #expect(result.isError && result.payload.stringValue?.contains(Self.refusal) == true, "PostgreSQL \(version) \(user): \(result.payload)")
            await client.close()
        }

        // The review's repros: a relation chosen at run time through table_to_xml. Outside the MCP tools it does read the
        // user mapping's password (the control); through run_query it is refused, for a plain role and for a pg_monitor member
        // even with the opt-in (which only lifts the role refusal).
        let userMappings = "SELECT table_to_xml(c.oid::regclass, true, false, '') FROM pg_class c WHERE c.relname = 'pg_user_' || 'mappings'"
        let activity = "SELECT table_to_xml(c.oid::regclass, true, false, '') FROM pg_class c WHERE c.relname = 'pg_stat_' || 'activity'"
        let direct = try await connect(version, user: "zz_mcp_plain")
        #expect(try await direct.simpleQuery(userMappings).lastRowSet?.scalar?.contains("zz-map-secret") == true, "control: the vector leaks")
        let directTools = tools(direct, user: "zz_mcp_plain")
        for sql in [userMappings, activity] {
            let refused = await directTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && refused.payload.stringValue?.contains("table_to_xml") == true, "PostgreSQL \(version): \(refused.payload)")
        }
        await direct.close()
        let monitor = try await connect(version, user: "zz_mcp_monitor")
        let monitorDefault = await tools(monitor, user: "zz_mcp_monitor").call(name: "run_query", arguments: ["sql": "SELECT 1"])
        #expect(monitorDefault.isError && monitorDefault.payload.stringValue?.contains(Self.refusal) == true, "\(monitorDefault.payload)")
        let monitorTools = tools(monitor, user: "zz_mcp_monitor", allowPrivileged: true)
        #expect(await monitorTools.call(name: "run_query", arguments: ["sql": "SELECT 1"]).isError == false, "allowed with the opt-in")
        let monitorRepro = await monitorTools.call(name: "run_query", arguments: ["sql": .string(activity)])
        #expect(monitorRepro.isError && monitorRepro.payload.stringValue?.contains("table_to_xml") == true, "\(monitorRepro.payload)")
        await monitor.close()

        // A plain role is allowed; SECURITY DEFINER helpers owned by a privileged role are reported, per database.
        let plain = try await connect(version, user: "zz_mcp_plain")
        let plainTools = tools(plain, user: "zz_mcp_plain")
        let read = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT current_user AS u"])
        #expect(!read.isError, "\(read.payload)")
        let notices = read.payload["security_notices"]?.arrayValue?.compactMap(\.stringValue).joined() ?? ""
        #expect(notices.contains("SECURITY DEFINER") && notices.contains("zz_mcp_secdef()"), "\(read.payload)")
        if major(admin) >= 11 { #expect(notices.contains("zz_mcp_secdef_proc()"), "procedures too: \(notices)") }
        let other = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1", "database": "postgres"])
        #expect(!other.isError, "\(other.payload)")
        #expect(other.payload["security_notices"]?.arrayValue?.contains { $0.stringValue?.contains("zz_mcp_secdef") == true } != true,
                "the check reads the database the call uses")
        #expect(await plainTools.call(name: "list_schemas", arguments: [:]).isError == false)

        // Foreign tables whose options run a program or read a server file, readable by the session (table or column grant),
        // are reported; one it cannot read is not. Reading one runs the program: the control for why it is reported.
        #expect(notices.contains("readable foreign tables run a server program or read a server file"), "\(notices)")
        for table in ["zz_mcp_prog_t", "zz_mcp_file_t", "zz_mcp_col_t"] { #expect(notices.contains("public.\(table)"), "\(table): \(notices)") }
        #expect(!notices.contains("zz_mcp_hidden_t"), "\(notices)")
        let ran = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT line FROM public.zz_mcp_prog_t"])
        #expect(ran.payload["rows"]?[0]?[0] == "zz-program-ran", "control: reading the table runs its program: \(ran.payload)")

        // Error responses carry the notices: a failing statement, a failing EXPLAIN ANALYZE, a metadata tool's error.
        let failures = [
            ("division by zero", await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1 / 0"])),
            ("division by zero", await plainTools.call(name: "explain_query", arguments: ["sql": "SELECT 1 / 0", "analyze": true])),
            ("No table or view", await plainTools.call(name: "describe_table", arguments: ["schema": "public", "table": "zz_mcp_missing"])),
        ]
        for (expected, failure) in failures {
            let text = failure.payload.stringValue ?? ""
            #expect(failure.isError && text.contains(expected), "PostgreSQL \(version): \(failure.payload)")
            #expect(text.contains("\n\nsecurity_notices:\n- ") && text.contains("zz_mcp_secdef()") && text.contains("public.zz_mcp_prog_t"),
                    "PostgreSQL \(version): \(text)")
        }

        // Writes a READ ONLY transaction does not stop: outside the MCP tools, BRIN summarisation and GIN pending-list cleanup
        // change the indexes inside BEGIN READ ONLY … ROLLBACK (the control: a second run finds nothing left to do); through
        // run_query they are refused before anything runs.
        _ = try await admin.simpleQuery("INSERT INTO public.zz_mcp_brin SELECT g, to_tsvector('simple', 'w' || g) FROM generate_series(1, 20000) g")
        for sql in ["SELECT brin_summarize_new_values('public.zz_mcp_brin_i')", "SELECT brin_summarize_range('public.zz_mcp_brin_i', 0)",
                    "SELECT gin_clean_pending_list('public.zz_mcp_gin_i')"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && refused.payload.stringValue?.contains("side effects outside the query") == true, "\(sql): \(refused.payload)")
        }
        let maintenance = try await connect(version, user: "zz_mcp_plain")
        let summarize = "BEGIN READ ONLY; SELECT brin_summarize_new_values('public.zz_mcp_brin_i') || ',' || gin_clean_pending_list('public.zz_mcp_gin_i'); ROLLBACK"
        let first = try await maintenance.simpleQuery(summarize).lastRowSet?.scalar ?? ""
        #expect(first != "0,0" && !first.isEmpty, "control: the first run writes the indexes: \(first)")
        #expect(try await maintenance.simpleQuery(summarize).lastRowSet?.scalar == "0,0", "control: the writes outlived the ROLLBACK")
        await maintenance.close()

        // Role settings can hold secrets. The role's own session reads them (the controls); through run_query every lookup of a
        // custom parameter, a name built at run time, the catalogs that list role settings and SHOW ALL are refused, and no
        // response holds the value. Built-in parameters stay readable.
        let settings = try await connect(version, user: "zz_mcp_plain")
        #expect(try await settings.simpleQuery("SELECT current_setting('zz_mcp.api_key')").lastRowSet?.scalar == "zz-role-secret", "control")
        #expect(try await settings.simpleQuery("SELECT rolconfig::text FROM pg_roles WHERE rolname = current_user").lastRowSet?.scalar?
            .contains("zz-role-secret") == true, "control")
        await settings.close()
        for sql in ["SELECT current_setting('zz_mcp.api_key')", "SELECT current_setting('zz_mcp' || '.api_key')", "SHOW zz_mcp.api_key",
                    "SHOW \"zz_mcp.api_key\"", "SELECT rolconfig FROM pg_roles", "SELECT * FROM pg_roles", "SELECT r FROM pg_roles r",
                    "SELECT useconfig FROM pg_user", "SELECT * FROM pg_db_role_setting", "SHOW ALL", "SELECT * FROM pg_settings"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && !"\(refused.payload)".contains("zz-role-secret"), "PostgreSQL \(version) \(sql): \(refused.payload)")
        }
        for sql in ["SHOW work_mem", "SELECT current_setting('server_version_num') AS v", "SELECT current_setting('search_path', true) AS p"] {
            let read = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(!read.isError, "PostgreSQL \(version) \(sql): \(read.payload)")
        }

        // The review's SHOW repros: U&-escaped names spell the dot (`\002e`) and ALL. Outside the MCP tools they read the
        // database and the role secret (the controls); through run_query each is refused and no response holds a secret.
        let escaped = try await connect(version, user: "zz_mcp_plain")
        #expect(try await escaped.simpleQuery(#"SHOW U&"zz_mcp\002ejwt_secret""#).lastRowSet?.scalar == "zz-db-secret", "control")
        #expect(try await escaped.simpleQuery(#"SHOW U&"zz_mcp\002eapi_key""#).lastRowSet?.scalar == "zz-role-secret", "control")
        await escaped.close()
        for sql in [#"SHOW U&"zz_mcp\002ejwt_secret""#, #"SHOW U&"zz_mcp!002ejwt_secret" UESCAPE '!'"#, #"SHOW U&"zz_mcp\+00002ejwt_secret""#,
                    #"SHOW U&"zz_mcp\002eapi_key""#, #"SHOW "all""#, #"SHOW "ALL""#, #"SHOW U&"\0061ll""#, "SHOW zz_mcp.jwt_secret"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            let text = "\(refused.payload)"
            #expect(refused.isError && !text.contains("zz-db-secret") && !text.contains("zz-role-secret"), "PostgreSQL \(version) \(sql): \(text)")
        }

        // Single-byte databases: every call's role check reads its database's encoding, and there an unquoted non-ASCII name is
        // refused (the server folds it by locale); quoted names, data and the UTF8 database are unaffected.
        for (database, encoding) in Self.singleByteDatabases {
            for (tool, sql) in [("run_query", "SELECT 1 AS café"), ("explain_query", "SELECT 1 AS naïve")] {
                let refused = await plainTools.call(name: tool, arguments: ["sql": .string(sql), "database": .string(database)])
                #expect(refused.isError && refused.payload.stringValue?.contains("single-byte encoding (\(encoding))") == true,
                        "PostgreSQL \(version) \(database) \(tool): \(refused.payload)")
            }
            let quoted = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 'café' AS \"café\"", "database": .string(database)])
            #expect(!quoted.isError && quoted.payload["rows"]?[0]?[0] == "café", "PostgreSQL \(version) \(database): \(quoted.payload)")
        }
        let utf8Names = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1 AS café"])
        #expect(!utf8Names.isError, "PostgreSQL \(version) UTF8: \(utf8Names.payload)")
        for sql in ["SELECT * FROM PG_SETTİNGS", "SELECT current_settİng('zz_mcp.api_key')", "SELECT pg_termİnate_backend(1)"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && !"\(refused.payload)".contains("zz-role-secret"), "PostgreSQL \(version) \(sql): \(refused.payload)")
        }

        // Functions in untrusted languages: a superuser's LANGUAGE internal aliases, executable by PUBLIC by default. Outside the
        // MCP tools they read server files and list the data directory as a plain role (the controls). Through run_query a call by
        // name is refused and every call's notices list them, with the C functions of extensions that are not reviewed
        // (pg_stat_statements, file_fdw, postgres_fdw) and the readable postgres_fdw table. Aggregates and range constructors,
        // also language internal, are not listed.
        let untrustedDirect = try await connect(version, user: "zz_mcp_plain")
        #expect(try await untrustedDirect.simpleQuery("SELECT public.zz_mcp_peek('PG_VERSION')").lastRowSet?.scalar?
            .hasPrefix(String(major(admin))) == true, "control: the alias reads a server file")
        #expect((try await untrustedDirect.simpleQuery("SELECT count(*) FROM public.zz_mcp_dir('.')").lastRowSet?.scalar).flatMap { Int($0) } ?? 0 > 0,
                "control: the alias lists the data directory")
        await untrustedDirect.close()
        for sql in ["SELECT public.zz_mcp_peek('PG_VERSION')", "SELECT ZZ_MCP_PEEK('pg_hba.conf')", "SELECT * FROM public.zz_mcp_dir('.')",
                    "SELECT \"zz_mcp_peek\"('postgresql.auto.conf')", "SELECT pg_stat_statements(true)"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && refused.payload.stringValue?.contains("untrusted language") == true
                || refused.payload.stringValue?.contains("other sessions' SQL") == true, "PostgreSQL \(version) \(sql): \(refused.payload)")
        }
        let reported = (await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1"])).payload["security_notices"]?.arrayValue?
            .compactMap(\.stringValue).joined(separator: "\n") ?? ""
        for expected in ["callable functions in untrusted languages", "public.zz_mcp_peek(text)", "public.zz_mcp_dir(text)", "pg_stat_statements(",
                         "file_fdw_handler()", "postgres_fdw_handler()", "readable foreign tables of other wrappers", "public.zz_mcp_remote_t"] {
            #expect(reported.contains(expected), "PostgreSQL \(version): \(expected) in \(reported)")
        }
        #expect(!reported.contains("zz_mcp_sum") && !reported.contains("zz_mcp_range") && !reported.contains("plpgsql"), "\(reported)")
        // Best effort, documented: a view calls the function implicitly. The control is EXECUTE: once revoked, the view fails
        // for the role and the notice no longer lists the function.
        let throughView = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT v FROM public.zz_mcp_peek_v"])
        #expect(!throughView.isError, "a view calls the function implicitly: \(throughView.payload)")
        _ = try await admin.simpleQuery("REVOKE EXECUTE ON FUNCTION public.zz_mcp_peek(text) FROM PUBLIC")
        let revoked = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT v FROM public.zz_mcp_peek_v"])
        let revokedText = revoked.payload.stringValue ?? ""
        #expect(revoked.isError && revokedText.contains("permission denied") && !revokedText.contains("zz_mcp_peek(text)")
            && revokedText.contains("zz_mcp_dir(text)"), "PostgreSQL \(version): \(revokedText)")

        // A forbidden schema on the search path: an unqualified call reaches it, which no text check can see (the controls).
        // Every call on such a connection is refused, opt-in or not, and its search path is left as it is.
        let pathClient = try await connect(version, user: "zz_mcp_path")
        #expect(try await pathClient.simpleQuery("SELECT open_cursor()").lastRowSet?.scalar == "7", "control: the call reaches dbms_sql")
        #expect(ReadOnlySQLGuard.check("SELECT open_cursor()") == nil, "control: the text check cannot see where a call resolves")
        let pathRefusal = "search_path includes dbms_sql; AI read-only mode refuses this connection"
        for (tool, arguments) in [("run_query", ["sql": JSONValue.string("SELECT open_cursor()")]), ("explain_query", ["sql": "SELECT 1"]),
                                  ("list_schemas", [:]), ("get_settings", [:])] {
            let refused = await tools(pathClient, user: "zz_mcp_path").call(name: tool, arguments: arguments)
            #expect(refused.isError && refused.payload.stringValue?.hasPrefix(pathRefusal) == true, "PostgreSQL \(version) \(tool): \(refused.payload)")
        }
        let optedIn = await tools(pathClient, user: "zz_mcp_path", allowPrivileged: true).call(name: "run_query", arguments: ["sql": "SELECT 1"])
        #expect(optedIn.isError && optedIn.payload.stringValue?.hasPrefix(pathRefusal) == true, "\(optedIn.payload)")
        #expect(try await pathClient.simpleQuery("SHOW search_path").lastRowSet?.scalar == "public, dbms_sql", "not rewritten")
        await pathClient.close()

        // get_settings and list_roles give what run_query refuses, without what can hold secrets. Controls: pg_settings lists
        // custom (dotted) parameters, and the role has a setting holding the secret and a password.
        let dotted = try await admin.records("SELECT count(*) AS n FROM pg_settings WHERE name LIKE '%.%'").first?.int("n") ?? 0
        #expect(dotted > 0, "control: pg_settings lists custom parameters")
        let hash = try await admin.records("SELECT rolpassword FROM pg_authid WHERE rolname = 'zz_mcp_plain'").first?.text("rolpassword") ?? ""
        #expect(hash.hasPrefix("SCRAM-SHA-256$"), "control: the role has a password")
        let settingsTool = await plainTools.call(name: "get_settings", arguments: [:])
        let settingNames = settingsTool.payload["settings"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(!settingsTool.isError && settingNames.contains("work_mem") && settingNames.contains("search_path") && settingNames.count > 100,
                "PostgreSQL \(version): \(settingNames.count) settings")
        #expect(!settingNames.contains { $0.contains(".") }, "PostgreSQL \(version): \(settingNames.filter { $0.contains(".") })")
        let settingsText = "\(settingsTool.payload)"
        for absent in ["zz-role-secret", "api_key", "zz_mcp.", "pg_stat_statements.", "sourcefile", "sourceline"] {
            #expect(!settingsText.contains(absent), "PostgreSQL \(version): get_settings shows \(absent)")
        }
        #expect(settingsTool.payload["security_notices"]?.arrayValue?.isEmpty == false, "through the role check, with its notices")
        let vacuum = await plainTools.call(name: "get_settings", arguments: ["filter": "VACUUM"])
        let vacuumNames = vacuum.payload["settings"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(!vacuumNames.isEmpty && vacuumNames.allSatisfy { $0.contains("vacuum") }, "\(vacuumNames)")
        for filter in ["pg_stat_statements", "api_key", "."] {
            let custom = await plainTools.call(name: "get_settings", arguments: ["filter": .string(filter)])
            #expect(custom.payload["count"] == .int(0), "PostgreSQL \(version) filter \(filter): \(custom.payload)")
        }
        let rolesTool = await plainTools.call(name: "list_roles", arguments: [:])
        #expect(!rolesTool.isError, "\(rolesTool.payload)")
        let rolesText = "\(rolesTool.payload)"
        for absent in ["zz-role-secret", "api_key", "rolconfig", "rolpassword", "SCRAM", hash] {
            #expect(!rolesText.contains(absent), "PostgreSQL \(version): list_roles shows \(absent)")
        }
        // (The notices name functions such as file_fdw_validator; the role data itself has no validity field.)
        #expect(!"\(rolesTool.payload["roles"] ?? .null)".contains("valid"), "PostgreSQL \(version): list_roles shows password validity")
        let listed = Dictionary((rolesTool.payload["roles"]?.arrayValue ?? []).compactMap { role in role["name"]?.stringValue.map { ($0, role) } },
                                uniquingKeysWith: { first, _ in first })
        #expect(listed["zz_mcp_member"]?["member_of"]?.arrayValue?.contains(.string("zz_mcp_super")) == true, "memberships")
        #expect(listed["zz_mcp_plain"]?["can_login"] == .bool(true) && listed["zz_mcp_plain"]?["superuser"] == .bool(false))
        #expect(listed["zz_mcp_plain"]?["inherit"] == .bool(true) && listed["zz_mcp_noinherit"]?["inherit"] == .bool(false), "rolinherit")
        #expect(!rolesText.contains("comment"), "role comments are free text and never listed")
        #expect(listed["zz_mcp_super"]?["superuser"] == .bool(true) && listed["zz_mcp_super"]?["can_login"] == .bool(false))
        #expect(rolesTool.payload["security_notices"]?.arrayValue?.isEmpty == false, "through the role check, with its notices")

        // The real control: SQL built at run time passes any text guard, and the server refuses it for a plain role.
        // `COPY (SELECT 1) TO PROGRAM 'exit 7'`, base64-encoded (the guard refuses a plain `'CO' || 'PY … TO PROGRAM …'`).
        let built = "SELECT public.zz_mcp_exec(convert_from(decode('Q09QWSAoU0VMRUNUIDEpIFRPIFBST0dSQU0gJ2V4aXQgNyc=', 'base64'), 'UTF8'))"
        #expect(ReadOnlySQLGuard.check(built) == nil, "a text guard cannot see SQL built at run time")
        let copy = await plainTools.call(name: "run_query", arguments: ["sql": .string(built)])
        #expect(copy.isError && copy.payload.stringValue?.contains("external program") == true, "PostgreSQL \(version): \(copy.payload)")
        // Opted in on the superuser, nothing stops it: the program runs (and exits 7).
        let unsafe = await tools(admin, user: "ccinn", allowPrivileged: true).call(name: "run_query", arguments: ["sql": .string(built)])
        #expect(unsafe.payload.stringValue?.contains("program \"exit 7\" failed") == true, "\(unsafe.payload)")

        // NUL: refused by the guard and never sent, whatever the role.
        for sql in ["SELECT pg_read\u{0}_file('/etc/hostname')", "SELECT count(*) FROM pg_ls\u{0}_dir('.')", "SELECT 1 IN\u{0}TO public.zz_mcp_nul_t"] {
            let refused = await plainTools.call(name: "run_query", arguments: ["sql": .string(sql)])
            #expect(refused.isError && refused.payload.stringValue?.contains("NUL") == true, "\(sql.debugDescription): \(refused.payload)")
        }
        #expect(try await admin.records("SELECT to_regclass('public.zz_mcp_nul_t') IS NULL AS absent").first?.bool("absent") == true)
        await #expect(throws: PostgresError.self) { _ = try await admin.simpleQuery("SELECT 1 IN\u{0}TO public.zz_mcp_nul_t") }

        // Re-checked on every call: a GRANT between calls is seen by the next one, on the same pooled connections.
        _ = try await admin.simpleQuery("GRANT zz_mcp_super TO zz_mcp_plain")
        let granted = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1"])
        #expect(granted.isError && granted.payload.stringValue?.contains(Self.refusal) == true, "\(granted.payload)")
        _ = try await admin.simpleQuery("REVOKE zz_mcp_super FROM zz_mcp_plain")
        #expect(await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1"]).isError == false)

        // Fails closed: when the check itself cannot run, the call is refused.
        _ = try await admin.simpleQuery("REVOKE SELECT ON pg_catalog.pg_auth_members FROM PUBLIC")
        let unchecked = await plainTools.call(name: "run_query", arguments: ["sql": "SELECT 1"])
        _ = try await admin.simpleQuery("GRANT SELECT ON pg_catalog.pg_auth_members TO PUBLIC")
        #expect(unchecked.isError && unchecked.payload.stringValue?.contains("Could not check this connection's role") == true, "\(unchecked.payload)")
        await plain.close()

        // client_encoding: the startup packet's UTF8 outranks ALTER ROLE … SET client_encoding = 'SJIS', and a string ending
        // in a backslash after a multibyte character still splits where the guard splits it.
        let encoded = try await connect(version, user: "zz_mcp_enc")
        let encodedTools = tools(encoded, user: "zz_mcp_enc")
        let setting = await encodedTools.call(name: "run_query", arguments: ["sql": "SELECT current_setting('client_encoding') AS e"])
        #expect(setting.payload["rows"]?[0]?[0] == "UTF8", "\(setting.payload)")
        let split = await encodedTools.call(name: "run_query", arguments: ["sql": "SELECT E'ソ\\\\' AS a, ' , x' AS b"])
        #expect(split.payload["rows"]?[0]?[0] == "ソ\\" && split.payload["rows"]?[0]?[1] == " , x", "\(split.payload)")
        await encoded.close()
    }
}

/// Secret-bearing catalog sources and redacted tools on real servers.
@Suite("MCP secret sources", .enabled(if: IT.enabled), .serialized)
struct MCPSecretSourceIntegrationTests {
    /// Catalog relations whose matching columns are not secret, with the reason (and a live check where it matters).
    static let harmless: [String: String] = [
        "pg_class": "reloptions are storage parameters (fillfactor, autovacuum_*)",
        "pg_attribute": "attoptions are per-column statistics settings, attfdwoptions remote column names",
        "pg_tablespace": "spcoptions are planner cost settings",
        "pg_proc": "proconfig is a function's own SET clauses, part of its definition like its body",
        "pg_extension": "extconfig lists an extension's configuration tables by OID",
        "pg_config": "build configuration (paths, compiler flags); superuser-only by default",
    ]

    /// Every pg_catalog view, table and function with a query, conninfo, password, options, config or setting result column
    /// is refused by the guard or proven harmless: a new server version's additions fail here instead of leaking.
    @Test(arguments: IT.versions)
    func everySecretLookingCatalogSourceIsCovered(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        defer { Task { await client.close() } }
        let relations = try await client.records("""
            SELECT DISTINCT c.relname AS name FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
              JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
             WHERE n.nspname = 'pg_catalog' AND c.relkind IN ('r', 'v', 'm') AND a.attnum > 0 AND NOT a.attisdropped
               AND a.attname ~ '(query|conninfo|passw|options|config|setting)'
            """).compactMap { $0.text("name") }
        let functions = try await client.records("""
            SELECT DISTINCT f.proname AS name FROM (
              SELECT p.proname, a.name, a.mode FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace,
                LATERAL unnest(p.proargnames, coalesce(p.proargmodes, array_fill('i'::"char", ARRAY[cardinality(p.proargnames)]))) AS a(name, mode)
               WHERE n.nspname = 'pg_catalog' AND p.proargnames IS NOT NULL) f
             WHERE f.mode IN ('o', 't', 'b') AND f.name ~ '(query|conninfo|passw|options|config|setting)'
            """).compactMap { $0.text("name") }
        #expect(relations.contains("pg_stat_activity") && functions.contains("pg_stat_get_activity"), "the enumeration works")
        #expect(relations.contains("pg_roles") && relations.contains("pg_settings") && functions.contains("pg_show_all_settings"), "settings too")
        for name in relations + functions {
            let refused = ReadOnlySQLGuard.isSecretSource(name) || ReadOnlySQLGuard.isForbiddenFunction(name)
            #expect(refused || Self.harmless[name] != nil, "PostgreSQL \(version): \(name) is neither refused nor proven harmless")
            if refused {
                #expect(ReadOnlySQLGuard.check("SELECT * FROM pg_catalog.\(name)") != nil, "\(name)")
            }
        }
    }

    /// VOLATILE core functions (the server makes no promise they are free of side effects) that are not forbidden, with the
    /// reason each is harmless in a READ ONLY transaction. Prefixes cover families.
    static let harmlessVolatile: [String: String] = [
        "amvalidate": "checks an operator class definition", "array_sample": "random choice from its argument",
        "array_shuffle": "random order of its argument", "bernoulli": "TABLESAMPLE method (internal argument)",
        "system": "TABLESAMPLE method (internal argument)", "brinhandler": "access method handler (internal argument)",
        "bthandler": "access method handler (internal argument)", "ginhandler": "access method handler (internal argument)",
        "gisthandler": "access method handler (internal argument)", "hashhandler": "access method handler (internal argument)",
        "spghandler": "access method handler (internal argument)", "heap_tableam_handler": "table access method handler (internal argument)",
        "plpgsql_call_handler": "language handler, not callable as a function", "plpgsql_inline_handler": "language handler (internal argument)",
        "plpgsql_validator": "checks a PL/pgSQL function body", "dsnowball_init": "text search dictionary support (internal argument)",
        "dsnowball_lexize": "text search dictionary support (internal argument)", "clock_timestamp": "the time", "timeofday": "the time",
        "timezone": "time zone conversion", "random": "a random number", "random_normal": "a random number", "gen_random_uuid": "a random UUID",
        "uuidv4": "a random UUID", "uuidv7": "a time-ordered UUID", "current_query": "this session's own statement",
        "currtid": "returns a tuple id, no data", "currtid2": "returns a tuple id, no data", "currval": "this session's last sequence value",
        "lastval": "this session's last sequence value", "pg_sequence_last_value": "a sequence value, privilege-checked like SELECT",
        "pg_get_sequence_data": "a sequence's state, privilege-checked like SELECT", "pg_export_snapshot": "names this transaction's snapshot; ends with it",
        "pg_sleep": "waits, within the statement timeout", "pg_sleep_for": "waits, within the statement timeout",
        "pg_sleep_until": "waits, within the statement timeout", "pg_stat_clear_snapshot": "drops this session's own statistics snapshot",
        "pg_stat_have_stats": "whether statistics exist", "pg_stat_get_io": "I/O counters", "pg_stat_get_backend_io": "I/O counters",
        "pg_stat_get_backend_wal": "WAL counters", "pg_stat_get_recovery_prefetch": "recovery prefetch counters",
        "pg_blocking_pids": "process ids", "pg_safe_snapshot_blocking_pids": "process ids", "pg_isolation_test_session_is_blocked": "a lock wait test",
        "pg_lock_status": "the lock table", "pg_get_multixact_members": "transaction ids locking a row", "pg_prepared_xact": "prepared transaction ids and owners",
        "pg_notification_queue_usage": "how full the NOTIFY queue is", "pg_collation_actual_version": "the system collation version",
        "pg_database_collation_actual_version": "the system collation version", "pg_control_checkpoint": "pg_control fields",
        "pg_control_init": "pg_control fields", "pg_control_recovery": "pg_control fields", "pg_control_system": "pg_control fields",
        "pg_current_wal_flush_lsn": "a WAL position", "pg_current_wal_insert_lsn": "a WAL position", "pg_current_wal_lsn": "a WAL position",
        "pg_last_wal_receive_lsn": "a WAL position", "pg_last_wal_replay_lsn": "a WAL position", "pg_last_xact_replay_timestamp": "a replay time",
        "pg_last_committed_xact": "a transaction id and time", "pg_xact_commit_timestamp": "a commit time", "pg_xact_commit_timestamp_origin": "a commit time",
        "pg_xact_status": "a transaction's status", "txid_status": "a transaction's status", "pg_is_in_recovery": "recovery state",
        "pg_is_wal_replay_paused": "recovery state", "pg_get_wal_replay_pause_state": "recovery state", "pg_is_in_backup": "backup state",
        "pg_database_size": "a size", "pg_indexes_size": "a size", "pg_relation_size": "a size", "pg_table_size": "a size",
        "pg_tablespace_size": "a size", "pg_total_relation_size": "a size", "pg_partition_ancestors": "partition hierarchy",
        "pg_partition_tree": "partition hierarchy", "pg_jit_available": "whether JIT is available", "pg_get_aios": "I/O in flight, no data",
        "pg_get_backend_memory_contexts": "this session's own memory use", "pg_get_loaded_modules": "loaded libraries",
        "pg_get_shmem_allocations": "shared memory layout", "pg_get_shmem_allocations_numa": "shared memory layout",
        "pg_get_wait_events": "wait event names", "pg_get_wal_resource_managers": "WAL resource manager names",
        "pg_get_wal_summarizer_state": "WAL summarizer state", "pg_available_wal_summaries": "WAL summary file list",
        "pg_wal_summary_contents": "block numbers in a WAL summary", "pg_show_replication_origin_status": "replication origin positions",
        "suppress_redundant_updates_trigger": "trigger function (runs only when fired by a trigger)",
        "tsvector_update_trigger": "trigger function (runs only when fired by a trigger)",
        "tsvector_update_trigger_column": "trigger function (runs only when fired by a trigger)",
        "unique_key_recheck": "trigger function (runs only when fired by a trigger)",
    ]
    static let harmlessVolatilePrefixes: [String: String] = [
        "RI_FKey_": "foreign-key trigger functions (run only when fired by a trigger)",
        "pg_stat_get_xact_": "the current transaction's own statistics counters",
    ]

    /// Every VOLATILE core function is forbidden or on the curated harmless list: writes a READ ONLY transaction does not stop
    /// (`brin_summarize_new_values`, `gin_clean_pending_list`) are VOLATILE, so a new version's additions fail here.
    @Test(arguments: IT.versions)
    func everyVolatileCoreFunctionIsForbiddenOrHarmless(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        defer { Task { await client.close() } }
        let names = try await client.records("""
            SELECT DISTINCT p.proname AS name FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'pg_catalog' AND p.provolatile = 'v'
            """).compactMap { $0.text("name") }
        #expect(names.contains("brin_summarize_new_values") && names.contains("gin_clean_pending_list"), "the enumeration works")
        for name in names.sorted() {
            let forbidden = ReadOnlySQLGuard.isForbiddenFunction(name) || ReadOnlySQLGuard.isSecretSource(name)
            let harmless = Self.harmlessVolatile[name] != nil || Self.harmlessVolatilePrefixes.keys.contains { name.hasPrefix($0) }
            #expect(forbidden != harmless, "PostgreSQL \(version): \(name) is \(forbidden ? "forbidden and listed harmless" : "neither forbidden nor proven harmless")")
            if forbidden { #expect(ReadOnlySQLGuard.check("SELECT pg_catalog.\(name)()") != nil, "\(name)") }
        }
    }

    /// Core functions that read a relation chosen at run time or run SQL from a string (found by argument type and name, and
    /// by the C entry points known to do it) are forbidden or proven harmless: a new version's additions fail here.
    static let harmlessFunctions: [String: String] = [
        "currtid2": "returns a tuple id, no data", "has_sequence_privilege": "a privilege check", "pg_get_serial_sequence": "a name",
        "pg_relation_filenode": "metadata", "pg_relation_filepath": "metadata", "pg_relation_is_publishable": "metadata",
        "pg_relation_is_updatable": "metadata", "pg_relation_size": "metadata", "pg_total_relation_size": "metadata",
        "pg_sequence_last_value": "a sequence value, privilege-checked like SELECT", "pg_get_sequence_data": "a sequence value, privilege-checked",
        "pg_split_walfile_name": "parses a file name", "phraseto_tsquery": "parses text", "plainto_tsquery": "parses text",
        "to_tsquery": "parses text", "websearch_to_tsquery": "parses text", "xml": "parses text", "xml_is_well_formed": "parses text",
        "xml_is_well_formed_content": "parses text", "xml_is_well_formed_document": "parses text", "xmlcomment": "builds a comment",
        "xmlexists": "evaluates XPath on its argument", "xmltext": "escapes text", "xmlvalidate": "not implemented (always an error)",
    ]

    @Test(arguments: IT.versions)
    func runTimeRelationAndSQLReadersAreForbidden(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        defer { Task { await client.close() } }
        let rows = try await client.records("""
            SELECT DISTINCT p.proname AS name, p.prosrc AS src FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = 'pg_catalog'
               AND p.prolang IN (SELECT oid FROM pg_catalog.pg_language WHERE lanname IN ('internal', 'c'))
               AND (p.prosrc IN ('table_to_xml', 'table_to_xmlschema', 'table_to_xml_and_xmlschema', 'query_to_xml', 'query_to_xmlschema',
                                 'query_to_xml_and_xmlschema', 'cursor_to_xml', 'cursor_to_xmlschema', 'schema_to_xml', 'schema_to_xmlschema',
                                 'schema_to_xml_and_xmlschema', 'database_to_xml', 'database_to_xmlschema', 'database_to_xml_and_xmlschema',
                                 'ts_stat1', 'ts_stat2', 'tsquery_rewrite_query')
                    OR ((p.proargtypes::oid[] && ARRAY['text'::regtype, 'regclass'::regtype, 'refcursor'::regtype, 'name'::regtype]::oid[]
                         OR p.pronargs = 3 AND p.proname ~ '_to_xml')
                        AND p.proname ~ '(xml|query|cursor|^ts_stat|rewrite|exec|_sql|eval|^lo_|dblink|file|table_to|schema_to|database_to|currtid|relation|sequence|tuple|prewarm|visib|heap|page)'))
            """)
        let names = Set(rows.compactMap { $0.text("name") })
        #expect(names.contains("table_to_xml") && names.contains("ts_stat"), "the enumeration works")
        for name in names.sorted() {
            let forbidden = ReadOnlySQLGuard.isForbiddenFunction(name) || ReadOnlySQLGuard.isSecretSource(name)
            #expect(forbidden || Self.harmlessFunctions[name] != nil, "PostgreSQL \(version): \(name) is neither forbidden nor proven harmless")
            if forbidden { #expect(ReadOnlySQLGuard.check("SELECT pg_catalog.\(name)('x')") != nil, "\(name)") }
        }
    }

    /// Extensions not on `MCPRoleCheck.reviewedExtensions`, with why: their C functions are reported as untrusted with every
    /// call and refused when called by name. pg_net and http are not in the images; they are listed for the record.
    static let notReviewed: [String: String] = [
        "adminpack": "writes server files", "amcheck": "reads index and heap pages", "autoinc": "trigger function", "bloom": "index method",
        "bool_plperl": "PL/Perl transform", "bool_plperlu": "PL/PerlU transform", "dblink": "connects to any server",
        "dict_int": "text search dictionary", "dict_xsyn": "text search dictionary, reads a server file", "file_fdw": "reads server files or runs programs",
        "hstore_plperl": "PL/Perl transform", "hstore_plperlu": "PL/PerlU transform", "hstore_plpython2u": "PL/Python transform",
        "hstore_plpython3u": "PL/Python transform", "hstore_plpythonu": "PL/Python transform", "insert_username": "trigger function",
        "intagg": "aggregate helpers", "jsonb_plperl": "PL/Perl transform", "jsonb_plperlu": "PL/PerlU transform", "jsonb_plpython2u": "PL/Python transform",
        "jsonb_plpython3u": "PL/Python transform", "jsonb_plpythonu": "PL/Python transform", "lo": "large object maintenance",
        "ltree_plpython2u": "PL/Python transform", "ltree_plpython3u": "PL/Python transform", "ltree_plpythonu": "PL/Python transform",
        "moddatetime": "trigger function", "pageinspect": "reads raw pages", "pg_buffercache": "shared buffers of every database",
        "pg_freespacemap": "free space map", "pg_logicalinspect": "logical decoding snapshots", "pg_prewarm": "loads relations into memory",
        "pg_stat_statements": "returns every user's queries", "pg_surgery": "writes heap pages past READ ONLY", "pg_visibility": "writes visibility maps",
        "pg_walinspect": "reads WAL", "pgrowlocks": "row locks of other sessions", "pgstattuple": "reads every page",
        "plperl": "procedural language", "plperlu": "untrusted procedural language", "plpython3u": "untrusted procedural language",
        "pltcl": "procedural language", "pltclu": "untrusted procedural language", "postgres_fdw": "connects to other servers", "refint": "trigger function",
        "sslinfo": "TLS details of the session", "tablefunc": "crosstab / connectby run SQL given as text", "tcn": "trigger function",
        "tsm_system_rows": "TABLESAMPLE method", "tsm_system_time": "TABLESAMPLE method", "xml2": "xpath_table runs SQL given as text",
        "pg_net": "HTTP requests from the server", "http": "HTTP requests from the server",
    ]

    /// Every extension the tested images ship is reviewed or listed as not reviewed (exactly one): a new image's extensions
    /// fail here until someone reviews them.
    @Test(arguments: IT.versions)
    func everyShippedExtensionIsReviewedOrListed(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        defer { Task { await client.close() } }
        let names = try await client.records("SELECT name FROM pg_catalog.pg_available_extensions ORDER BY 1").compactMap { $0.text("name") }
        #expect(names.contains("pg_trgm") && names.contains("pg_stat_statements"), "the enumeration works")
        for name in names {
            let reviewed = MCPRoleCheck.reviewedExtensions.contains(name)
            #expect(reviewed != (Self.notReviewed[name] != nil), "PostgreSQL \(version): extension \(name) is \(reviewed ? "in both lists" : "not reviewed yet")")
        }
        for name in ["pg_stat_statements", "pageinspect", "pgstattuple", "pg_buffercache", "dblink", "postgres_fdw", "file_fdw", "tablefunc",
                     "adminpack", "pg_net", "http"] {
            #expect(Self.notReviewed[name] != nil && !MCPRoleCheck.reviewedExtensions.contains(name), "\(name)")
        }
    }

    /// get_activity and get_top_statements return other sessions' SQL with every literal replaced (a secret in a plain
    /// string literal included); the raw sources do hold it (the controls).
    @Test(arguments: IT.versions)
    func redactedToolsReplaceEveryLiteral(version: String) async throws {
        let admin = try await PostgresClient.connect(IT.configuration(version))
        defer { Task { await admin.close() } }
        let profile = ConnectionProfile(name: "IT \(version)", host: "127.0.0.1", port: IT.port(version), username: "ccinn", database: "ccinn",
                                        mcpAccess: .readOnly, mcpAllowPrivilegedRole: true)
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [profile], defaultProfile: nil, forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in admin }, audit: nil)

        let other = try await PostgresClient.connect(IT.configuration(version))
        let running = Task { try await other.simpleQuery("SELECT 'zz-secret-123' AS s, pg_sleep(3)") }
        var seen = false
        for _ in 0..<40 where !seen {
            try await Task.sleep(for: .milliseconds(100))
            seen = try await admin.records("SELECT count(*) AS n FROM pg_stat_activity WHERE query LIKE '%zz-secret-123%' AND pid <> pg_backend_pid()")
                .first?.int("n") ?? 0 > 0
        }
        #expect(seen, "control: the raw view shows the literal")
        let activity = await tools.call(name: "get_activity", arguments: [:])
        let text = "\(activity.payload)"
        #expect(!activity.isError, "\(activity.payload)")
        #expect(!text.contains("zz-secret-123"), "PostgreSQL \(version): \(text)")
        #expect(text.contains("pg_sleep(?)"), "the session is listed, digested")
        running.cancel()
        _ = try? await running.value
        await other.close()

        guard (Int(version.split(separator: ".").first ?? "") ?? 0) >= 17 else { return } // pg_stat_statements only there
        _ = try await admin.simpleQuery("DO $$BEGIN PERFORM pg_sleep(0.3); PERFORM 'zz-secret-456'; END$$")
        let raw = try await admin.records("SELECT count(*) AS n FROM pg_stat_statements WHERE query LIKE '%zz-secret-456%'")
        #expect(raw.first?.int("n") ?? 0 > 0, "control: pg_stat_statements keeps the utility statement's literal")
        let top = await tools.call(name: "get_top_statements", arguments: ["limit": 200])
        #expect(!top.isError, "\(top.payload)")
        #expect(!"\(top.payload)".contains("zz-secret-456"), "PostgreSQL \(version): the literal leaked")
        #expect("\(top.payload)".contains("DO ?"), "the statement is listed, digested")
    }
}
