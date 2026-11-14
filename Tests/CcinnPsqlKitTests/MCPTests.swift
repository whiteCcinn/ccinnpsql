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
        #expect(PostgresMCPTools.readOnlyEpilogue.hasPrefix("ROLLBACK;"))
        #expect(PostgresMCPTools.readOnlyEpilogue.contains("pg_advisory_unlock_all()"))
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
