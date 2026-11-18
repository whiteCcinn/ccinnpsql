import Foundation
import os
import Testing
@testable import CcinnPsqlKit
import PostgresKit

@Suite("MCP JSON and framing")
struct MCPJSONTests {
    @Test func parsesAndSerializesOnOneLine() throws {
        let value = try JSONValue.parse(#"{"a":[1,2.5,"x\ny",true,null],"b":{"c":"é🙂"}}"#)
        #expect(value["a"]?[0] == .int(1))
        #expect(value["a"]?[1] == .double(2.5))
        #expect(value["a"]?[3] == .bool(true))
        #expect(value["a"]?[4] == .null)
        let text = value.serialized()
        #expect(!text.contains("\n"))
        #expect(try JSONValue.parse(text) == value)
    }

    @Test func escapesControlCharactersAndQuotes() {
        #expect(JSONValue.string("a\"b\\c\u{01}\t\u{2028}").serialized() == #""a\"b\\c\u0001\t\u2028""#)
        #expect(JSONValue.double(.infinity).serialized() == "null")
    }

    @Test func rejectsInvalidAndDeepJSON() {
        #expect(throws: (any Error).self) { try JSONValue.parse("{nope") }
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        #expect(throws: (any Error).self) { try JSONValue.parse(deep) }
    }

    @Test func framerSplitsLinesAndBoundsLength() {
        var framer = LineFramer(maxLineBytes: 16)
        #expect(framer.append(Array("{\"a\":1}\n{\"b\"".utf8)) == [.line("{\"a\":1}")])
        #expect(framer.append(Array(":2}\r\n".utf8)) == [.line("{\"b\":2}")])
        #expect(framer.append(Array(String(repeating: "x", count: 40).utf8)) == [.oversized])
        #expect(framer.append(Array("yyy\n{}\n".utf8)) == [.line("{}")])
        #expect(framer.append(Array("\n\n".utf8)).isEmpty)
    }
}

private actor Transcript {
    private(set) var lines: [String] = []
    func append(_ line: String) { lines.append(line) }
    func messages() -> [JSONValue] { lines.compactMap { try? JSONValue.parse($0) } }
}

private struct FakeTools: MCPToolProvider {
    func tools() async -> [MCPTool] {
        [MCPTool(name: "echo", title: "Echo", description: "Echoes", inputSchema: .object(["type": "object"]), readOnly: true),
         MCPTool(name: "slow", title: "Slow", description: "Sleeps", inputSchema: .object(["type": "object"]), readOnly: true)]
    }

    func call(name: String, arguments: [String: JSONValue]) async -> MCPToolResult {
        switch name {
        case "echo": return .success(.object(["echo": arguments["text"] ?? .null]))
        case "slow":
            do {
                try await Task.sleep(for: .seconds(30))
                return .success(.string("done"))
            } catch {
                return .failure("cancelled")
            }
        default: return .failure("Unknown tool \(name)")
        }
    }
}

@Suite("MCP protocol")
struct MCPServerTests {
    private func makeServer() -> (MCPServer, Transcript) {
        let transcript = Transcript()
        let server = MCPServer(info: MCPServerInfo(name: "test", title: "Test", version: "1.0.0", instructions: "Test server"),
                               provider: FakeTools(), send: { await transcript.append($0) })
        return (server, transcript)
    }

    @Test func negotiatesKnownAndUnknownVersions() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":"two","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["result"]?["protocolVersion"] == .string("2025-03-26"))
        #expect(messages[0]["result"]?["capabilities"]?["tools"]?["listChanged"] == .bool(false))
        #expect(messages[0]["result"]?["serverInfo"]?["name"] == .string("test"))
        #expect(messages[1]["id"] == .string("two"))
        #expect(messages[1]["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(messages[2]["result"]?["protocolVersion"] == .string("2024-11-05"))
    }

    @Test func listsAndCallsTools() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await server.waitForIdle()
        let messages = await transcript.messages()
        #expect(messages.count == 3)
        #expect(messages[1]["result"]?["tools"]?[0]?["annotations"]?["readOnlyHint"] == .bool(true))
        #expect(messages[2]["result"]?["structuredContent"]?["echo"] == .string("hi"))
    }

    @Test func olderProtocolsGetNoStructuredContent() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hi"}}}"#)
        await server.waitForIdle()
        let messages = await transcript.messages()
        #expect(messages[1]["result"]?["structuredContent"] == nil)
        #expect(messages[1]["result"]?["content"]?[0]?["type"] == .string("text"))
    }

    @Test func protocolErrors() async throws {
        let (server, transcript) = makeServer()
        await server.receive("{not json")
        await server.receive(#"{"jsonrpc":"2.0","id":7,"method":"no/such"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"arguments":{}}}"#)
        await server.receive(#"[{"jsonrpc":"2.0","id":9,"method":"ping"}]"#)
        await server.receive(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":11,"method":"prompts/list"}"#)
        await server.receive(#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"echo","arguments":[1]}}"#)
        let messages = await transcript.messages()
        #expect(messages[0]["error"]?["code"] == .int(-32700))
        #expect(messages[1]["error"]?["code"] == .int(-32601))
        #expect(messages[2]["error"]?["code"] == .int(-32602))
        #expect(messages[3]["error"]?["code"] == .int(-32600))
        #expect(messages[4]["result"] == .object([:]))
        #expect(messages[5]["result"]?["prompts"] == .array([]))
        #expect(messages[6]["error"]?["code"] == .int(-32602))
    }

    @Test func cancelledCallsGetNoResponse() async throws {
        let (server, transcript) = makeServer()
        await server.receive(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"slow"}}"#)
        try await Task.sleep(for: .milliseconds(50))
        await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"user"}}"#)
        await server.waitForIdle()
        #expect(await transcript.messages().isEmpty)
    }
}

@Suite("MCP profiles, tools and results")
struct MCPProfileTests {
    static let profiles = [
        ConnectionProfile(name: "Prod", host: "prod", mcpAccess: .readOnly),
        ConnectionProfile(name: "Dev", host: "dev", mcpAccess: .readWrite),
        ConnectionProfile(name: "Secret", host: "secret"),
    ]

    @Test func legacyProfilesDecodeWithDefaults() throws {
        let json = #"[{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","host":"h","port":5432,"username":"app","createdAt":0}]"#
        let decoded = try JSONDecoder().decode([ConnectionProfile].self, from: Data(json.utf8))
        #expect(decoded.first?.mcpAccess == .disabled)
        #expect(decoded.first?.sslMode == .prefer)
        #expect(decoded.first?.poolingMode == .auto)
        #expect(decoded.first?.effectiveDatabase == "postgres")
    }

    @Test func resolvesExplicitDefaultAndSingleProfile() throws {
        let resolver = MCPProfileResolver(profiles: Self.profiles, defaultProfile: nil, forceReadOnly: false)
        #expect(try resolver.resolve("prod").profile.name == "Prod")
        #expect(try resolver.resolve(Self.profiles[1].id.uuidString).access == .readWrite)
        #expect(throws: MCPToolError.self) { try resolver.resolve(nil) }
        #expect(throws: MCPToolError.self) { try resolver.resolve("Secret") }
        #expect(throws: MCPToolError.self) { try resolver.resolve("nope") }
        #expect(resolver.enabledProfiles.map(\.name) == ["Dev", "Prod"])
        let capped = MCPProfileResolver(profiles: Self.profiles, defaultProfile: "Dev", forceReadOnly: true)
        #expect(try capped.resolve(nil).access == .readOnly)
        #expect(!capped.anyWritable)
        let single = MCPProfileResolver(profiles: [Self.profiles[0], Self.profiles[2]], defaultProfile: nil, forceReadOnly: false)
        #expect(try single.resolve(nil).profile.name == "Prod")
    }

    @Test func toolListDependsOnAccess() async {
        let readOnly = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [Self.profiles[0]], defaultProfile: nil, forceReadOnly: false),
                                        registry: MCPClientRegistry { _ in throw PostgresError(.network, "offline") }, audit: nil)
        let names = await readOnly.tools().map(\.name)
        #expect(names.contains("run_query") && names.contains("explain_query") && names.contains("get_activity"))
        #expect(!names.contains("execute_statement"))
        for tool in await readOnly.tools() {
            #expect(tool.inputSchema["additionalProperties"] == .bool(false), "\(tool.name)")
            #expect(tool.inputSchema["type"] == .string("object"))
        }
        let writable = PostgresMCPTools(resolver: MCPProfileResolver(profiles: Self.profiles, defaultProfile: nil, forceReadOnly: false),
                                        registry: MCPClientRegistry { _ in throw PostgresError(.network, "offline") }, audit: nil)
        let write = await writable.tools().first { $0.name == "execute_statement" }
        #expect(write?.destructive == true)
    }

    /// Review findings 1 and 3: the runner pins the string-literal rules the guard lexes with, and leaves no
    /// session-level advisory lock on a pooled connection.
    @Test func readOnlyRunnerPinsLexingAndCleansSessionState() {
        let preamble = PostgresMCPTools.readOnlyPreamble(timeout: 30)
        #expect(preamble.hasPrefix("BEGIN TRANSACTION READ ONLY;"))
        #expect(preamble.contains("SET LOCAL statement_timeout = 30000"))
        #expect(preamble.contains("SET LOCAL standard_conforming_strings = on"))
        // Lead review, layer 2: every call ends with a session reset before the connection is reused.
        #expect(PostgresMCPTools.sessionReset(keepsSessionState: true) == ["ROLLBACK", "DISCARD ALL"])
        let pooled = PostgresMCPTools.sessionReset(keepsSessionState: false).joined(separator: "; ")
        #expect(pooled.hasPrefix("ROLLBACK;"))
        for part in ["pg_advisory_unlock_all()", "UNLISTEN *", "RESET ALL"] { #expect(pooled.contains(part)) }
        #expect(!pooled.contains("DISCARD ALL") && !pooled.contains("DEALLOCATE"))
    }

    @Test func guardRejectsBeforeConnecting() async throws {
        let opened = OSAllocatedUnfairLock(initialState: 0)
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [Self.profiles[0]], defaultProfile: nil, forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in
                                         opened.withLock { $0 += 1 }
                                         throw PostgresError(.network, "offline")
                                     }, audit: nil)
        // The registry is consulted before the guard here only for metadata; run_query with a write fails on the guard.
        let result = await tools.call(name: "run_query", arguments: ["sql": "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d"])
        #expect(result.isError)
        #expect(result.payload.stringValue?.contains("read-only") == true)
        #expect(opened.withLock { $0 } == 0)
        let execute = await tools.call(name: "execute_statement", arguments: ["sql": "DELETE FROM t"])
        #expect(execute.isError)
        #expect(execute.payload.stringValue?.contains("read-only") == true)
        let unknown = await tools.call(name: "drop_everything", arguments: [:])
        #expect(unknown.isError)
        let missing = await tools.call(name: "list_tables", arguments: [:])
        #expect(missing.isError)
    }

    @Test func encodesRowsWithTypesAndTruncatesBySize() {
        let columns = [ColumnInfoLite(name: "id", kind: .integer, typeName: "int8"), ColumnInfoLite(name: "total", kind: .decimal, typeName: "numeric"),
                       ColumnInfoLite(name: "ok", kind: .boolean, typeName: "bool"), ColumnInfoLite(name: "doc", kind: .json, typeName: "jsonb"),
                       ColumnInfoLite(name: "city", kind: .text, typeName: "text")]
        let rows: [[String?]] = (0..<5_000).map { [String($0), "12.50", "t", "{\"a\": 1}", String(repeating: "k", count: 100)] }
        let encoded = MCPResultEncoder.rows(columns: columns, rows: rows, truncatedByServer: false, maxBytes: 64 * 1024)
        #expect(encoded["truncated"] == .bool(true))
        let returned = encoded["rows"]?.arrayValue ?? []
        #expect(returned.count < 5_000 && !returned.isEmpty)
        #expect(returned.first?[0] == .int(0))
        #expect(returned.first?[1] == .string("12.50"))
        #expect(returned.first?[2] == .bool(true))
        #expect(returned.first?[3]?["a"] == .int(1))
        #expect(encoded.serialized().utf8.count <= 64 * 1024 + 512)
    }

    @Test func auditRedactsAndUsesPrivateFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-audit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let audit = MCPAuditLog(directory: directory)
        await audit.record(tool: "execute_statement", connection: "Dev", statement: "CREATE ROLE x PASSWORD 'p4ss'", durationMilliseconds: 1.25,
                           rows: nil, error: nil)
        let text = try String(contentsOf: audit.fileURL, encoding: .utf8)
        #expect(text.contains("PASSWORD '***'"))
        #expect(!text.contains("p4ss"))
        let permissions = try FileManager.default.attributesOfItem(atPath: audit.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}

/// The read-only MCP role check, decided from the catalog's answer (fake answers here; the query itself runs in the
/// integration tests on every server version).
@Suite("MCP role check")
struct MCPRoleCheckTests {
    private func answer(privileged: String? = "{}", count: String? = "0", definers: String? = "{}", encoding: String? = "UTF8",
                        fileTableCount: String? = "0", fileTables: String? = "{}", serverEncoding: String? = "UTF8",
                        encodingMaxLength: String? = "4", untrustedCount: String? = "0", untrusted: String? = "{}", untrustedNames: String? = "{}",
                        foreignTableCount: String? = "0", foreignTables: String? = "{}") -> ResultSet {
        ResultSet(columns: ["privileged_roles", "definer_count", "definers", "client_encoding", "file_table_count", "file_tables", "server_encoding",
                            "encoding_max_length", "untrusted_count", "untrusted", "untrusted_names", "foreign_table_count", "foreign_tables"]
                    .map { ColumnDescription(name: $0, typeOID: 25) },
                  rows: [[privileged, count, definers, encoding, fileTableCount, fileTables, serverEncoding, encodingMaxLength, untrustedCount, untrusted,
                          untrustedNames, foreignTableCount, foreignTables]])
    }

    // Functions in untrusted languages (internal, C, plpython3u, plperlu, …) that the session may execute, outside pg_catalog,
    // information_schema and the reviewed extensions: a superuser's `LANGUAGE internal AS 'pg_read_file_all'` alias is
    // executable by PUBLIC and read server files as a plain role in the review. Reported, and direct calls by name refused
    // (best effort: views, operators, casts, defaults and RLS call functions too; the control is revoking EXECUTE).
    @Test func untrustedLanguageFunctionsAreReportedAndDirectCallsRefused() throws {
        let check = try inspect(answer(untrustedCount: "3", untrusted: "{public.zz_peek(text),ext.zz_dir(text),public.\"Mixed\"(integer)}",
                                       untrustedNames: "{Mixed,zz_dir,zz_peek}"))
        #expect(check.refusal(.refusePrivileged) == nil, "reported; only direct calls are refused")
        let notice = try #require(check.notices(.refusePrivileged).first)
        #expect(notice.hasPrefix("3 callable functions in untrusted languages (internal, C, plpython3u, …) outside pg_catalog and reviewed "
            + "extensions run with the server's access; the read-only check can't see inside them and refuses direct calls to them"), "\(notice)")
        #expect(notice.contains("public.zz_peek(text)") && notice.contains("ext.zz_dir(text)"))
        for sql in ["SELECT zz_peek('PG_VERSION')", "SELECT public.ZZ_PEEK('pg_hba.conf')", "SELECT \"zz_peek\"('x')", "SELECT * FROM ext.zz_dir('.')",
                    "SELECT \"Mixed\"(1)", "SELECT f(zz_peek('x'))", "SELECT zz_exec('SELECT zz_peek(''x'')')", "SELECT zz_exec('x := zz_dir(''.'')')"] {
            #expect(check.refusal(forStatement: sql)?.contains("untrusted language") == true, "\(sql)")
        }
        // (Call-like text in a literal is checked like a call, as for every forbidden function; a plain name is data.)
        for sql in ["SELECT mixed(1)", "SELECT zz_peek FROM t", "SELECT 'zz_peek' AS text", "SELECT zz_peek_v FROM v"] {
            #expect(check.refusal(forStatement: sql) == nil, "\(sql)")
        }
        #expect(try inspect(answer()).refusal(forStatement: "SELECT zz_peek('x')") == nil, "only the session's own list counts")
    }

    // Readable foreign tables of other wrappers (postgres_fdw, …) reach a fixed remote destination: informational.
    @Test func otherForeignTablesAreReported() throws {
        let check = try inspect(answer(foreignTableCount: "1", foreignTables: "{public.remote_orders}"))
        #expect(check.refusal(.refusePrivileged) == nil)
        #expect(check.notices(.refusePrivileged) == ["1 readable foreign tables of other wrappers (postgres_fdw, …) read a fixed remote "
            + "destination when read: public.remote_orders"])
    }

    // The check runs in every database, whatever its encoding: a non-ASCII character in its text (a `…` in a comment) cannot
    // be converted to LATIN1 or SQL_ASCII, so the check failed and every call there was refused.
    @Test func theCheckIsPlainASCII() {
        let nonASCII = (MCPRoleCheck.query + MCPRoleCheck.searchPathQuery).unicodeScalars.filter { !$0.isASCII }
        #expect(nonASCII.isEmpty, "\(String(String.UnicodeScalarView(nonASCII)))")
    }

    // The reviewed extensions, whose own functions are trusted not to read or write outside the database or other sessions.
    @Test func theReviewedExtensionsAreExactlyTheAgreedList() {
        #expect(MCPRoleCheck.reviewedExtensions == ["plpgsql", "pg_trgm", "btree_gin", "btree_gist", "citext", "hstore", "cube", "earthdistance",
                                                    "fuzzystrmatch", "intarray", "isn", "ltree", "seg", "unaccent", "uuid-ossp", "pgcrypto", "vector",
                                                    "postgis", "postgis_raster", "postgis_topology"])
        let query = MCPRoleCheck.query
        #expect(query.contains(MCPRoleCheck.reviewedExtensionsSQL))
        for name in MCPRoleCheck.reviewedExtensions { #expect(MCPRoleCheck.reviewedExtensionsSQL.contains("'\(name)'"), "\(name)") }
        for name in ["pg_stat_statements", "pageinspect", "pgstattuple", "pg_buffercache", "dblink", "postgres_fdw", "file_fdw", "tablefunc",
                     "adminpack", "pg_net", "http"] {
            #expect(!MCPRoleCheck.reviewedExtensions.contains(name) && !MCPRoleCheck.reviewedExtensionsSQL.contains("'\(name)'"),
                    "\(name) is deliberately not reviewed")
        }
        for fragment in ["NOT l.lanpltrusted", "has_function_privilege(f.oid, 'EXECUTE')", "d.deptype = 'e'", "f.prokind <> 'a'",
                         "('pg_catalog', 'information_schema')", "w.fdwname <> 'file_fdw'"] {
            #expect(query.contains(fragment), "\(fragment)")
        }
    }

    // The database encoding, read in every call's role check: in a single-byte one the server folds non-ASCII letters in
    // unquoted names by locale (Turkish `İ` became `i` in the review), so the statement may only use ASCII there. Fails closed.
    @Test func singleByteDatabasesAreDetectedAndTheirStatementsChecked() throws {
        let latin5 = try inspect(answer(serverEncoding: "LATIN5", encodingMaxLength: "1"))
        #expect(latin5.singleByteEncoding == "LATIN5" && latin5.refusal(.refusePrivileged) == nil)
        let message = "this database uses a single-byte encoding (LATIN5), where the server folds non-ASCII letters in names by locale; "
            + "quote the name or use ASCII"
        for sql in ["SELECT café FROM t", "SELECT * FROM t WHERE x = naïve"] {
            #expect(latin5.refusal(forStatement: sql)?.contains(message) == true, "\(sql)")
        }
        #expect(latin5.refusal(forStatement: "SELECT \"café\" FROM t WHERE x = 'café'") == nil)
        let ascii = try inspect(answer(serverEncoding: "SQL_ASCII", encodingMaxLength: "1"))
        #expect(ascii.refusal(forStatement: "SELECT café FROM t")?.contains("single-byte encoding (SQL_ASCII)") == true)
        let utf8 = try inspect(answer())
        #expect(utf8.singleByteEncoding == nil && utf8.refusal(forStatement: "SELECT café FROM t") == nil)
        #expect(utf8.refusal(forStatement: "SELECT * FROM PG_SETTİNGS") != nil, "the 19 letters, in every encoding")
        #expect(throws: MCPToolError.self) { try inspect(answer(encodingMaxLength: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(encodingMaxLength: "one")) }
        #expect(throws: MCPToolError.self) { try inspect(answer(serverEncoding: nil)) }
        #expect(MCPRoleCheck.query.contains("pg_catalog.pg_encoding_max_length(d.encoding)"))
    }

    /// The session's `current_schemas(true)`, read before the check pins search_path.
    private func searchPath(_ schemas: String? = "{pg_catalog,public}") -> ResultSet {
        ResultSet(columns: [ColumnDescription(name: "search_schemas", typeOID: 1009)], rows: [[schemas]])
    }

    private func inspect(_ answer: ResultSet, searchPath path: ResultSet? = nil) throws -> MCPRoleCheck {
        try MCPRoleCheck(answer, searchPath: path ?? searchPath())
    }

    // orafce's schemas run SQL given as text or act outside the transaction under generic names (`open_cursor()`, `fopen()`):
    // with one on the search path an unqualified call reaches it, so the connection is refused, whatever the policy.
    @Test func aForbiddenSchemaOnTheSearchPathIsRefused() throws {
        for schema in ["dbms_sql", "dbms_pipe", "dbms_alert", "utl_file", "DBMS_SQL"] {
            let check = try inspect(answer(), searchPath: searchPath("{pg_catalog,public,\(schema)}"))
            for policy in [MCPRolePolicy.refusePrivileged, .allowPrivileged] {
                let refusal = check.refusal(policy) ?? ""
                #expect(refusal.hasPrefix("search_path includes \(schema); AI read-only mode refuses this connection"), "\(schema): \(refusal)")
            }
        }
        #expect(try inspect(answer(), searchPath: searchPath("{pg_temp_3,pg_catalog,\"$user\",public,dbms_sql_notes}")).refusal(.refusePrivileged) == nil)
        #expect(try inspect(answer()).searchPathSchemas == ["pg_catalog", "public"])
        #expect(throws: MCPToolError.self) { try MCPRoleCheck(answer(), searchPath: searchPath(nil)) }
        #expect(throws: MCPToolError.self) { try MCPRoleCheck(answer(), searchPath: ResultSet(columns: [], rows: [])) }
        #expect(MCPRoleCheck.searchPathQuery.contains("pg_catalog.current_schemas(true)"))
    }

    @Test func aPlainRoleIsAllowed() throws {
        let check = try inspect(answer())
        #expect(check.refusal(.refusePrivileged) == nil)
        #expect(check.notices(.refusePrivileged).isEmpty)
    }

    // A superuser reachable through any membership, the roles that run server programs or touch server files, and those
    // that read every session's SQL and every setting (pg_read_all_stats, pg_read_all_settings, pg_monitor).
    @Test(arguments: ["{ccinn}", "{pg_execute_server_program}", "{pg_read_server_files}", "{pg_write_server_files}", "{admin,pg_read_server_files}",
                      "{pg_read_all_stats}", "{pg_read_all_settings}", "{pg_monitor}"])
    func privilegedRolesAreRefusedUnlessAllowed(roles: String) throws {
        let check = try inspect(answer(privileged: roles))
        let refusal = try #require(check.refusal(.refusePrivileged))
        #expect(refusal.contains("This connection's role can run server programs, touch server files or read every session's SQL and settings, which a read-only check can't prevent."))
        #expect(refusal.contains("Connect with a less privileged role, or allow it for this connection in AI settings."))
        #expect(refusal.contains(roles.trimmingCharacters(in: CharacterSet(charactersIn: "{}")).split(separator: ",").first.map(String.init) ?? "?"))
        #expect(check.refusal(.allowPrivileged) == nil, "the per-connection opt-in")
        #expect(check.notices(.allowPrivileged).contains { $0.contains("allowed for this connection") })
    }

    // The guard lexes UTF-8: any other client encoding (SJIS, BIG5, GBK, … where `\` can be a trailing byte) is refused,
    // even with the opt-in.
    @Test func otherClientEncodingsAreAlwaysRefused() throws {
        for encoding in ["SJIS", "BIG5", "GBK", "GB18030", "JOHAB", "LATIN1"] {
            let check = try inspect(answer(encoding: encoding))
            #expect(check.refusal(.refusePrivileged)?.contains("client_encoding") == true, "\(encoding)")
            #expect(check.refusal(.allowPrivileged) != nil, "\(encoding)")
        }
    }

    @Test func securityDefinerHelpersAreReported() throws {
        let check = try inspect(answer(count: "3", definers: "{public.zz_secdef(),\"odd \"\"name\"\"\"(),ext.helper(integer)}"))
        #expect(check.refusal(.refusePrivileged) == nil, "reported, not refused")
        let notice = try #require(check.notices(.refusePrivileged).first)
        #expect(notice.hasPrefix("3 SECURITY DEFINER functions owned by privileged roles are callable; the read-only check can't see inside them"))
        #expect(notice.contains("public.zz_secdef()") && notice.contains("ext.helper(integer)"))
    }

    // A foreign table whose options run a program or read a server file (file_fdw `program` / `filename`, on the table, its
    // server or its wrapper) runs that program or reads that file each time it is read: reported, like SECURITY DEFINER
    // helpers, on success and on errors.
    @Test func fileReadingForeignTablesAreReported() throws {
        // As the server sends `ARRAY[…::regclass::text]`: a quoted identifier inside a quoted, backslash-escaped element.
        let check = try inspect(answer(fileTableCount: "2", fileTables: #"{public.zz_prog,"public.\"odd \"\"t\"\"\""}"#))
        #expect(check.refusal(.refusePrivileged) == nil, "reported, not refused")
        let notice = try #require(check.notices(.refusePrivileged).first)
        #expect(notice.hasPrefix("2 readable foreign tables run a server program or read a server file when read (file_fdw program / filename "
            + "options); the read-only check can't prevent that"), "\(notice)")
        #expect(notice.contains("public.zz_prog") && notice.contains(#"public."odd ""t""""#), "\(notice)")
        let more = try inspect(answer(fileTableCount: "25", fileTables: "{public.a}"))
        #expect(more.notices(.refusePrivileged).first?.hasSuffix("public.a, …") == true)
        #expect(MCPRoleCheck.query.contains("'program'") && MCPRoleCheck.query.contains("'filename'"))
        #expect(MCPRoleCheck.query.contains("has_any_column_privilege"), "column grants count as readable")
        #expect(MCPRoleCheck.query.contains("srvoptions") && MCPRoleCheck.query.contains("fdwoptions") && MCPRoleCheck.query.contains("ftoptions"))
    }

    // Error responses carry the notices too, after the message.
    @Test func failuresCarryTheSecurityNotices() {
        #expect(PostgresMCPTools.failureMessage("division by zero", notices: []) == "division by zero")
        let message = PostgresMCPTools.failureMessage("division by zero", notices: ["one", "two"])
        #expect(message == "division by zero\n\nsecurity_notices:\n- one\n- two")
    }

    // Anything but the expected answer fails closed: the call is refused.
    @Test func unexpectedAnswersFailClosed() {
        #expect(throws: MCPToolError.self) { try inspect(answer(privileged: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(count: "many")) }
        #expect(throws: MCPToolError.self) { try inspect(answer(encoding: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(fileTableCount: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(fileTableCount: "x")) }
        #expect(throws: MCPToolError.self) { try inspect(answer(fileTables: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(untrustedCount: "x")) }
        #expect(throws: MCPToolError.self) { try inspect(answer(untrustedNames: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(untrusted: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(foreignTableCount: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(answer(foreignTables: nil)) }
        #expect(throws: MCPToolError.self) { try inspect(ResultSet(columns: [], rows: [])) }
        #expect(throws: MCPToolError.self) {
            try inspect(ResultSet(columns: [ColumnDescription(name: "privileged_roles", typeOID: 25)], rows: [["{}"]]))
        }
    }

    // Read-only access checks the role (refusing privileged roles unless the connection allows them); read & write access
    // already lets the AI run anything the role can.
    @Test func thePolicyFollowsAccessAndTheOptIn() {
        let plain = ConnectionProfile(name: "p", mcpAccess: .readOnly)
        var allowed = plain
        allowed.mcpAllowPrivilegedRole = true
        #expect(PostgresMCPTools.rolePolicy(for: .init(profile: plain, access: .readOnly)) == .refusePrivileged)
        #expect(PostgresMCPTools.rolePolicy(for: .init(profile: allowed, access: .readOnly)) == .allowPrivileged)
        #expect(PostgresMCPTools.rolePolicy(for: .init(profile: plain, access: .readWrite)) == nil)
    }

    // The query's target set, kept in step with the decision's documentation.
    @Test func theCheckCoversEveryPrivilegedBuiltInRole() {
        for role in ["pg_execute_server_program", "pg_read_server_files", "pg_write_server_files", "pg_read_all_stats", "pg_read_all_settings", "pg_monitor"] {
            #expect(MCPRoleCheck.query.contains("'\(role)'"), "\(role)")
            #expect(MCPRoleCheck.privilegedBuiltInRoles.contains(role), "\(role)")
        }
        #expect(MCPRoleCheck.query.contains("rolsuper"))
    }

    @Test func theOptInIsOffByDefaultAndPersists() throws {
        #expect(ConnectionProfile().mcpAllowPrivilegedRole == false)
        let legacy = #"[{"id":"7B0A9E6C-3C3A-4B8E-9C5B-1D6F2E0A4A11","name":"Old","host":"h","port":5432,"username":"app","createdAt":0}]"#
        #expect(try JSONDecoder().decode([ConnectionProfile].self, from: Data(legacy.utf8)).first?.mcpAllowPrivilegedRole == false)
        var profile = ConnectionProfile(name: "x", mcpAccess: .readOnly)
        profile.mcpAllowPrivilegedRole = true
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.mcpAllowPrivilegedRole)
    }

    // The guard checks exactly the text that is sent: run_query's statement after AutoLimit, whatever the statement ended
    // with, and explain_query's after the EXPLAIN prefix.
    @Test func theGuardChecksTheTextAfterEveryRewrite() throws {
        for base in ["SELECT a FROM t", "SELECT a FROM t WHERE b = 1", "WITH x AS (SELECT 1) SELECT * FROM x"] {
            for tail in ["-", "/", "--", "/*", "*", "'", " -", " /", " --", " /*", " *", " '", "-- c\n", "/* c */"] {
                let sql = base + tail
                guard let prepared = try? PostgresMCPTools.prepareQuery(sql: sql, limit: 100) else { continue } // refused: fine
                #expect(ReadOnlySQLGuard.check(prepared.executed) == nil, "\(prepared.executed.debugDescription)")
                // The rewrite added tokens; it never changed how the statement's own text lexes.
                let statement = try #require(SQLStatementSplitter.split(sql).first?.text)
                let original = SQLLexer.tokenize(statement).map { SQLLexer(statement).text(in: $0.range) }
                let rewritten = SQLLexer(prepared.executed)
                var tokens = rewritten.tokens().map { rewritten.text(in: $0.range) }
                if prepared.limitApplied, let at = tokens.firstIndex(of: "LIMIT") { tokens.removeSubrange(at...(at + 1)) }
                #expect(tokens == original, "\(sql.debugDescription) -> \(prepared.executed.debugDescription)")
            }
            let explained = ExplainPlan.statement(for: base + " --", analyze: true, buffers: true)
            #expect(ReadOnlySQLGuard.check(explained) == nil)
        }
        #expect(throws: MCPToolError.self) { try PostgresMCPTools.prepareQuery(sql: "SELECT 1; DELETE FROM t", limit: 10) }
    }
}

/// Names in tool arguments reach the server as given (startup packet, catalog lookups, quoted identifiers): every argument
/// but the SQL text is refused when it holds a control character (Unicode Cc: NUL, C0, DEL, C1), before anything is sent.
@Suite("MCP argument text")
struct MCPArgumentTextTests {
    @Test func controlCharactersInNameArgumentsAreRefused() async {
        for (key, value) in [("database", "information_\u{0}schema"), ("schema", "pub\u{0}lic"), ("table", "tasks\u{1}"), ("connection", "prod\u{7F}"),
                             ("name_filter", "mv\u{85}"), ("filter", "work\u{9F}mem"), ("table", "t\n")] {
            #expect(MCPArguments([key: .string(value), "sql": .string("SELECT 1")]).controlCharacterArgument() == key, "\(key)")
        }
        #expect(MCPArguments(["sql": .string("SELECT\t1\n FROM t\u{0}"), "database": .string("shop"), "limit": .int(5)]).controlCharacterArgument() == nil,
                "the SQL text has its own checks (the guard refuses NUL)")
        #expect(MCPArguments(["schema": .string("café"), "table": .string("名前")]).controlCharacterArgument() == nil)

        // Refused by the dispatcher before a connection is resolved or opened (the registry would fail the test otherwise).
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [ConnectionProfile(name: "p", mcpAccess: .readOnly)], defaultProfile: nil,
                                                                  forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in throw MCPToolError("no connection may be opened") }, audit: nil)
        for (tool, arguments) in [("list_tables", ["schema": JSONValue.string("pub\u{0}lic")]), ("run_query", ["sql": "SELECT 1", "database": "d\u{0}b"]),
                                  ("describe_table", ["schema": "public", "table": "t\u{1B}"]), ("list_connections", ["connection": "p\u{0}"])] {
            let result = await tools.call(name: tool, arguments: arguments)
            #expect(result.isError && result.payload.stringValue?.contains("contains a control character") == true, "\(tool): \(result.payload)")
        }
    }
}

/// get_settings and list_roles: what the AI may see of server settings and roles, never what can hold secrets (custom
/// parameters, role settings, passwords, password expiry). Fake rows carry the forbidden columns and values too, so the
/// encoders' allowlists are what is tested; the queries never select them either.
@Suite("MCP settings and roles tools")
struct MCPSafeCatalogTests {
    private func setting(_ name: String, _ value: String, unit: String? = nil) -> Record {
        Record(["name": name, "setting": value, "unit": unit, "category": "Resource Usage / Memory", "short_desc": "d", "source": "default",
                "pending_restart": "f", "sourcefile": "/etc/postgresql/postgresql.conf", "sourceline": "12", "boot_val": "b", "reset_val": "r"])
    }

    @Test func settingsAreBuiltInParametersOnly() throws {
        let records = [setting("work_mem", "4096", unit: "kB"), setting("myapp.api_key", "zz-secret"), setting("pg_stat_statements.max", "5000"),
                       setting("search_path", "\"$user\", public")]
        let all = MCPSafeCatalog.settings(records, filter: nil)
        let text = "\(all)"
        for absent in ["myapp", "api_key", "zz-secret", "pg_stat_statements", "sourcefile", "sourceline", "/etc/postgresql", "boot_val", "reset_val"] {
            #expect(!text.contains(absent), "\(absent): \(text)")
        }
        let rows = try #require(all["settings"]?.arrayValue)
        #expect(rows.compactMap { $0["name"]?.stringValue } == ["work_mem", "search_path"])
        #expect(all["count"] == .int(2))
        let workMem = try #require(rows.first?.objectValue)
        #expect(Set(workMem.keys) == ["name", "setting", "unit", "category", "short_desc", "source", "pending_restart"])
        #expect(workMem["unit"] == .string("kB") && workMem["pending_restart"] == .bool(false))
        // The filter is a case-insensitive substring of the name, applied in the tool; it never brings a custom parameter back.
        #expect(MCPSafeCatalog.settings(records, filter: "WORK")["settings"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["work_mem"])
        for filter in ["api", ".", "myapp.api_key", "statements"] {
            #expect(MCPSafeCatalog.settings(records, filter: filter)["count"] == .int(0), "\(filter)")
        }
    }

    @Test func theSettingsQuerySelectsOnlyAllowedColumnsOfBuiltIns() {
        let query = MCPSafeCatalog.settingsQuery
        #expect(query.contains("strpos(s.name, '.') = 0"))
        for column in ["name", "setting", "unit", "category", "short_desc", "source", "pending_restart"] { #expect(query.contains("s.\(column)")) }
        for absent in ["sourcefile", "sourceline", "*", "reset_val", "boot_val"] { #expect(!query.contains(absent), "\(absent)") }
    }

    @Test func rolesNeverIncludeSettingsPasswordsOrExpiry() throws {
        let records = [
            Record(["rolname": "app", "rolsuper": "f", "rolinherit": "t", "rolcreaterole": "f", "rolcreatedb": "t", "rolcanlogin": "t", "rolreplication": "f",
                    "rolbypassrls": "f", "rolconnlimit": "-1", "member_of": "{pg_read_all_data,\"team a\"}",
                    "rolconfig": "{myapp.api_key=zz-secret}", "rolpassword": "SCRAM-SHA-256$4096:zz", "rolvaliduntil": "2030-01-01"]),
            Record(["rolname": "admin", "rolsuper": "t", "rolinherit": "f", "rolcreaterole": "t", "rolcreatedb": "t", "rolcanlogin": "f", "rolreplication": "t",
                    "rolbypassrls": "t", "rolconnlimit": "5", "member_of": "{}"]),
        ]
        let payload = MCPSafeCatalog.roles(records)
        let text = "\(payload)"
        for absent in ["rolconfig", "myapp", "zz-secret", "rolpassword", "SCRAM", "valid", "2030"] { #expect(!text.contains(absent), "\(absent): \(text)") }
        let roles = try #require(payload["roles"]?.arrayValue)
        let app = try #require(roles.first?.objectValue)
        #expect(Set(app.keys) == ["name", "superuser", "inherit", "create_role", "create_db", "can_login", "replication", "bypass_rls", "connection_limit",
                                  "member_of"])
        #expect(app["inherit"] == .bool(true) && roles.last?["inherit"] == .bool(false), "rolinherit, for reading memberships")
        #expect(app["name"] == .string("app") && app["create_db"] == .bool(true) && app["superuser"] == .bool(false))
        #expect(app["member_of"] == .array([.string("pg_read_all_data"), .string("team a")]) && app["connection_limit"] == .int(-1))
        #expect(roles.last?["superuser"] == .bool(true) && roles.last?["connection_limit"] == .int(5))
        #expect(payload["count"] == .int(2) && payload["truncated"] == .bool(false))
    }

    @Test func theRolesQueryNamesItsColumns() {
        let query = MCPSafeCatalog.rolesQuery
        for column in ["rolname", "rolsuper", "rolinherit", "rolcreaterole", "rolcreatedb", "rolcanlogin", "rolreplication", "rolbypassrls", "rolconnlimit"] {
            #expect(query.contains("r.\(column)"), "\(column)")
        }
        for absent in ["rolconfig", "rolpassword", "rolvaliduntil", "pg_authid", "pg_shadow", "*"] { #expect(!query.contains(absent), "\(absent)") }
    }

    @Test func bothToolsAreListedAsReadOnly() async {
        let tools = PostgresMCPTools(resolver: MCPProfileResolver(profiles: [ConnectionProfile(name: "p", mcpAccess: .readOnly)], defaultProfile: nil,
                                                                  forceReadOnly: false),
                                     registry: MCPClientRegistry { _ in throw MCPToolError("no server") }, audit: nil)
        let listed = await tools.tools()
        for name in ["get_settings", "list_roles"] {
            let tool = listed.first { $0.name == name }
            #expect(tool?.readOnly == true, "\(name)")
        }
    }
}
