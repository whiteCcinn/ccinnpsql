import Foundation
@testable import CcinnPsqlKit
import PostgresKit
import Testing

/// Drives the real `CcinnPsql mcp` subprocess over stdio against a test container. Requires `swift build` first
/// (the test runs `.build/debug/CcinnPsql`). The profile uses `trust_user` (trust authentication), so no secret has
/// to be handed to the subprocess.
@Suite("MCP server subprocess", .enabled(if: IT.enabled && MCPProcess.binaryExists), .serialized)
struct MCPSubprocessTests {
    @Test(arguments: IT.versions)
    func fullSessionOverStdio(version: String) async throws {
        let process = try MCPProcess(version: version)
        defer { process.terminate() }

        let initialize = try await process.request(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                    "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "it", "version": "1"]]])
        #expect(initialize["result"]?["serverInfo"]?["name"] == .string("ccinnpsql"))
        #expect(initialize["result"]?["protocolVersion"] == .string("2025-06-18"))
        try process.send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        let tools = try await process.request(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("run_query") && names.contains("get_activity") && names.contains("explain_query"))
        #expect(!names.contains("execute_statement"), "the test profile is read-only")

        let info = try await process.call(id: 3, "server_info", [:])
        #expect(info["tls"] == .bool(true))
        #expect(info["current_user"] == .string("trust_user"))

        let tables = try await process.call(id: 4, "list_tables", ["schema": "shop"])
        let kinds = Dictionary((tables["objects"]?.arrayValue ?? []).compactMap { object -> (String, String)? in
            guard let name = object["name"]?.stringValue, let kind = object["kind"]?.stringValue else { return nil }
            return (name, kind)
        }, uniquingKeysWith: { first, _ in first })
        #expect(kinds["orders"] == "table")
        #expect(kinds["daily_revenue"] == "materialized_view")
        #expect(kinds["paid_orders"] == "view")

        let describe = try await process.call(id: 5, "describe_table", ["schema": "shop", "table": "orders"])
        #expect(describe["columns"]?.arrayValue?.contains { $0["name"] == .string("customer_id") } == true)
        #expect(describe["ddl"]?.stringValue?.contains("CREATE TABLE shop.orders") == true)

        let query = try await process.call(id: 6, "run_query", ["sql": "SELECT * FROM shop.orders", "limit": 25])
        #expect(query["row_count"] == .int(25))
        #expect(query["truncated"] == .bool(true))
        #expect(query["limit_applied"] == .bool(true))

        let rejected = try await process.request(["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                  "params": ["name": "run_query", "arguments": ["sql": "DELETE FROM shop.orders"]]])
        #expect(rejected["result"]?["isError"] == .bool(true))

        let plan = try await process.call(id: 8, "explain_query", ["sql": "SELECT count(*) FROM shop.orders WHERE status = 'paid'", "analyze": true])
        #expect(plan["analyzed"] == .bool(true))
        #expect(plan["plan"]?.stringValue?.contains("Seq Scan") == true || plan["plan"]?.stringValue?.contains("Index") == true)

        let activity = try await process.call(id: 9, "get_activity", ["include_idle": true])
        #expect(activity["sessions"]?.arrayValue != nil)

        // Cancelling a long query stops it on the server and produces no response for that id.
        try process.send(["jsonrpc": "2.0", "id": 10, "method": "tools/call",
                          "params": ["name": "run_query", "arguments": ["sql": "SELECT pg_sleep(30) AS ccinnpsql_mcp_cancel_probe", "timeout_seconds": 60]]])
        try await Task.sleep(for: .milliseconds(800))
        try process.send(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 10]])
        let ping = try await process.request(["jsonrpc": "2.0", "id": 11, "method": "ping"])
        #expect(ping["result"] == .object([:]))
        try await Task.sleep(for: .seconds(2))
        #expect(process.responses(for: 10).isEmpty)
        let observer = try await IT.client(version)
        let still = try await observer.records("SELECT count(*) AS n FROM pg_stat_activity WHERE query LIKE '%ccinnpsql_mcp_cancel_probe%' AND pid <> pg_backend_pid() AND state = 'active'")
        #expect(still.first?.int("n") == 0, "the cancelled statement is still running on the server")
        await observer.close()
    }
}

/// A running MCP server subprocess with a temporary profile directory.
final class MCPProcess: @unchecked Sendable {
    static var binary: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/CcinnPsql")
    }

    static var binaryExists: Bool { FileManager.default.isExecutableFile(atPath: binary.path) }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let directory: URL
    private let lock = NSLock()
    private var buffer = Data()
    private var messages: [JSONValue] = []

    init(version: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = ConnectionProfile(name: "IT \(version)", host: "127.0.0.1", port: IT.port(version), username: "trust_user", database: "ccinn",
                                        sslMode: .prefer, connectTimeout: 30, mcpAccess: .readOnly)
        try ProfileRepository(directory: directory, secrets: InMemorySecretStore()).save([profile])

        process.executableURL = Self.binary
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["CCINNPSQL_PROFILE_DIR"] = directory.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                let line = self.buffer[self.buffer.startIndex..<newline]
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if let message = try? JSONValue.parse(Data(line)) { self.messages.append(message) }
            }
            self.lock.unlock()
        }
        try process.run()
    }

    func send(_ message: JSONValue) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((message.serialized() + "\n").utf8))
    }

    func responses(for id: Int64) -> [JSONValue] {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { $0["id"] == .int(id) }
    }

    func request(_ message: JSONValue, timeout: Duration = .seconds(90)) async throws -> JSONValue {
        try send(message)
        guard let id = message["id"]?.intValue else { return .null }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let response = responses(for: id).first { return response }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MCPToolError("No response to request \(id)")
    }

    /// Calls a tool and returns its structured result, failing the test on tool errors.
    func call(id: Int64, _ name: String, _ arguments: JSONValue) async throws -> JSONValue {
        let response = try await request(["jsonrpc": "2.0", "id": .int(id), "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]])
        let result = response["result"]
        if result?["isError"] == .bool(true) {
            throw MCPToolError("\(name) failed: \(result?["content"]?[0]?["text"]?.stringValue ?? "?")")
        }
        return result?["structuredContent"] ?? .null
    }

    func terminate() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: directory)
    }
}
