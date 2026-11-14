import Foundation
import PostgresKit
import PostgresWire
import Testing

/// PgBouncer (transaction pooling) and Pgpool-II in front of PostgreSQL 17 (`scripts/pooler-up.sh`); run with
/// `CCINNPSQL_IT=1 CCINNPSQL_IT_POOLERS=1`.
enum PoolerIT {
    static let enabled = IT.enabled && ProcessInfo.processInfo.environment["CCINNPSQL_IT_POOLERS"] == "1"

    static func configuration(port: Int, database: String = "ccinn") -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: port), username: "ccinn", password: "ccinn", database: database,
                                connectTimeout: 10, sslMode: .prefer)
    }
}

@Suite("Pooler integration", .enabled(if: PoolerIT.enabled), .serialized)
struct PoolerIntegrationTests {
    @Test func pgBouncerTransactionPooling() async throws {
        // PgBouncer has no TLS here: `prefer` gets "N" to the SSLRequest and falls back to a plain connection.
        let client = try await PostgresClient.connect(PoolerIT.configuration(port: 15430))
        defer { Task { await client.close() } }
        #expect(client.serverInfo.tlsDescription == nil)
        #expect(client.serverInfo.pooler == .pooler)
        #expect(client.serverInfo.poolingMode == .transaction)
        #expect(!client.serverInfo.keepsSessionState)

        // Catalog and extended-protocol queries work through the pooler (unnamed statements only).
        let contents = try await client.schemaContents("shop")
        #expect(contents.relations.contains { $0.name == "customers" })
        let binary = try await client.query("SELECT $1::int + 1 AS n, now() AS t", [.text("41")], resultFormat: .binaryWhereSupported)
        #expect(binary.lastRowSet?.scalar == "42")

        // Cancel reaches the server connection running the statement.
        let session = client.openSession()
        let started = ContinuousClock.now
        let running = Task { try await session.run("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(500))
        await session.cancel()
        do {
            _ = try await running.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(try await session.run("SELECT 1").lastRowSet?.scalar == "1")
        // Session settings are not replayed (they do not survive transactions anyway).
        _ = try await session.run("SET work_mem = '8MB'")
        #expect(await session.replayedSettings.isEmpty)
        await session.close()

        // LISTEN is refused with an explanation instead of silently never delivering.
        do {
            _ = try await PostgresListener.open(client: client)
            Issue.record("LISTEN allowed in transaction pooling")
        } catch let error as PostgresError {
            #expect(error.kind == .unsupported)
        }

        // A profile override wins over detection.
        let overridden = try await PostgresClient.connect(PoolerIT.configuration(port: 15430), poolingMode: .session)
        #expect(overridden.serverInfo.poolingMode == .session)
        await overridden.close()
    }

    @Test func pgBouncerAdminConsole() async throws {
        let client = try await PostgresClient.connect(PoolerIT.configuration(port: 15430, database: "pgbouncer"))
        defer { Task { await client.close() } }
        #expect(client.serverInfo.isPgBouncerConsole)
        let pools = try await client.poolerReport("POOLS")
        #expect(pools.lastRowSet?.columnNames.contains("database") == true)
        let stats = try await client.poolerReport("STATS")
        #expect(stats.lastRowSet?.hasRowSet == true)
        await #expect(throws: PostgresError.self) { _ = try await client.poolerReport("SHUTDOWN") }
    }

    @Test func pgpool() async throws {
        let client = try await PostgresClient.connect(PoolerIT.configuration(port: 15431))
        defer { Task { await client.close() } }
        guard case let .pgpool(version) = client.serverInfo.pooler else {
            Issue.record("Pgpool not detected: \(client.serverInfo.pooler)")
            return
        }
        #expect(version.contains("4.6"))
        #expect(client.serverInfo.poolingMode == .session)
        #expect(client.routingPrefix == "/*NO LOAD BALANCE*/ ")
        let snapshot = try await client.activity()
        #expect(!snapshot.sessions.isEmpty)
        let nodes = try await client.poolerReport("POOL_NODES")
        #expect(nodes.lastRowSet?.rows.isEmpty == false)

        // Cancel through Pgpool.
        let session = client.openSession()
        let running = Task { try await session.run("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(500))
        let started = ContinuousClock.now
        await session.cancel()
        do {
            _ = try await running.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        await session.close()

        // Guarded terminate through Pgpool reaches the backend observed in the snapshot.
        let victim = try await client.makeConnection()
        let pidRow = try await victim.extendedQuery("SELECT pg_backend_pid() AS pid").records.first
        let pid = try #require(pidRow?.int("pid").flatMap { Int32(exactly: $0) })
        let fresh = try await client.activity()
        #expect(try await client.terminateBackend(pid, observedOn: fresh.node))
        await victim.close()
    }
}
