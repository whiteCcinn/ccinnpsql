import Foundation
import os
import Testing
@testable import PostgresKit
import PostgresWire

/// Replies of a plain PostgreSQL 17 backend to the client's server-facts queries.
enum FakeFacts {
    static func reply(_ query: String, pid: Int32) -> FakePostgresServer.Reply? {
        if query.contains("server_version_num") {
            return .bytes(Wire.rows(["version", "num", "usr", "db", "in_recovery", "pid", "started_us", "server_addr", "server_port",
                                     "superuser", "max_connections"],
                                    [["PostgreSQL 17.2", "170002", "app", "app", "f", String(pid), "1700000000000000", "10.0.0.7", "5432",
                                      "f", "100"]]))
        }
        if query.contains("pg_extension") { return .bytes(Wire.rows(["extname", "extversion", "nspname"], [])) }
        if query == "SHOW pool_version" { return .bytes(Wire.error("42704", "unrecognized configuration parameter \"pool_version\"")) }
        return nil
    }
}

@Suite("Client with a fake server")
struct ClientTests {
    /// Review finding 10: a pooler that accepts the login but never answers must not hang `connect` forever.
    @Test func serverFactsAreBoundedByADeadline() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in query.contains("server_version_num") ? .hang : .bytes(Wire.complete("SELECT 0")) }
        }
        var configuration = fakeConfiguration()
        configuration.connectTimeout = 10
        #expect(PostgresClient.serverFactsTimeout(configuration) == 20)
        configuration.connectTimeout = 0.1
        #expect(PostgresClient.serverFactsTimeout(configuration) == 5)
        let started = ContinuousClock.now
        do {
            _ = try await Deadline.run(seconds: 30, timeoutError: { PostgresError(.timeout, "test watchdog") }) { [configuration] in
                try await PostgresClient.connect(configuration, transportFactory: network.factory)
            }
            Issue.record("connect succeeded without server facts")
        } catch let error as PostgresError {
            #expect(error.kind == .timeout)
            #expect(error.message != "test watchdog", "the client's own deadline did not fire")
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    /// Server errors from optional probes mean "not supported"; anything else must surface.
    @Test func probesSwallowOnlyServerErrors() async throws {
        let rejected: Int? = try await ServerInfo.probe { throw PostgresError(.server, "unrecognized configuration parameter") }
        #expect(rejected == nil)
        await #expect(throws: PostgresError.self) {
            let _: Int? = try await ServerInfo.probe { throw PostgresError(.timeout, "timed out") }
        }
        await #expect(throws: PostgresError.self) {
            let _: Int? = try await ServerInfo.probe { throw PostgresError(.connectionClosed, "closed") }
        }
    }

    /// Review finding 2: resolving type names while holding the only connection of a pool must not wait for a
    /// second connection; names are cached per database because user-type OIDs are per database.
    @Test func typeNamesResolveOnTheHeldConnectionAndPerDatabase() async throws {
        let network = FakeNetwork { index in
            let pid = Int32(100 + index)
            return FakePostgresServer(pid: pid) { query in
                if let reply = FakeFacts.reply(query, pid: pid) { return reply }
                if query == "SELECT e" { return .bytes(Wire.rowDescription(["e"], type: 70_000) + Wire.dataRow(["happy"]) + Wire.complete("SELECT 1")) }
                if query.contains("FROM pg_type") {
                    // Connection 1 serves database "other", connection 2 database "third": same OID, different types.
                    return .bytes(Wire.rows(["oid", "typname"], [["70000", index == 1 ? "mood" : "colour"]]))
                }
                return .bytes(Wire.complete("SELECT 0"))
            }
        }
        // poolSize 2 → pools for other databases hold a single connection.
        let client = try await PostgresClient.connect(fakeConfiguration(), poolSize: 2, transportFactory: network.factory)
        defer { Task { await client.close() } }
        func resolve(_ database: String) async throws -> String? {
            try await Deadline.run(seconds: 5, timeoutError: { PostgresError(.timeout, "type-name lookup waited for a second connection") }) {
                try await client.withConnection(database: database) { connection in
                    let result = try await connection.extendedQuery("SELECT e")
                    return try await client.resolvingTypeNames(result, database: database, using: connection).lastRowSet?.columns.first?.typeName
                }
            }
        }
        #expect(try await resolve("other") == "mood")
        #expect(try await resolve("third") == "colour")
        // Cached: a second lookup in "other" sends no pg_type query and keeps that database's name.
        let lookupsBefore = network.servers.withLock { $0 }.flatMap(\.queries).filter { $0.contains("FROM pg_type") }.count
        #expect(try await resolve("other") == "mood")
        let lookupsAfter = network.servers.withLock { $0 }.flatMap(\.queries).filter { $0.contains("FROM pg_type") }.count
        #expect(lookupsAfter == lookupsBefore)
    }

    @Test func builtInTypeOIDsShareOneCacheEntry() {
        #expect(TypeNameKey(oid: 25, database: "a") == TypeNameKey(oid: 25, database: "b"))
        #expect(TypeNameKey(oid: 16_384, database: "a") != TypeNameKey(oid: 16_384, database: "b"))
    }
}

/// Review finding 5: reaching the row limit must not cancel the statement (a cancel rolls back the batch's
/// uncommitted work); only a drain over budget is cancelled, and then reported as a rollback.
@Suite("Row limit draining")
struct RowLimitDrainTests {
    @Test func rowsPastTheLimitAreSkippedWithoutCancelling() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { _ in
                .bytes(Wire.complete("INSERT 0 1") + Wire.rows(["g"], (1...50).map { [String($0)] }) + Wire.complete("INSERT 0 1"))
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        defer { Task { await connection.close() } }
        let result = try await connection.simpleQuery("INSERT …; SELECT g …; INSERT …", limits: RowLimits(maxRows: 10))
        #expect(result.results.count == 3)
        #expect(result.results[1].rows.count == 10)
        #expect(result.results[1].isTruncated)
        #expect(result.completedStatements == 3)
        #expect(!result.cancelledAtRowLimit)
        #expect(!result.notices.contains { $0.severity == "WARNING" })
        let server = try #require(network.servers.withLock { $0.first })
        #expect(server.cancelCount == 0, "the row limit sent a CancelRequest")
    }

    @Test func aDrainOverBudgetIsCancelledAndReportedAsRolledBack() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { _ in
                .partialThenHang(Wire.complete("INSERT 0 1") + Wire.rowDescription(["g"]) + (1...20).flatMap { Wire.dataRow([String($0)]) })
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        defer { Task { await connection.close() } }
        let result = try await connection.simpleQuery("INSERT …; SELECT g …", limits: RowLimits(maxRows: 5, drainRows: 3))
        #expect(result.cancelledAtRowLimit)
        #expect(result.completedStatements == 1)
        #expect(result.results.last?.rows.count == 5)
        let warning = try #require(result.notices.last)
        #expect(warning.severity == "WARNING")
        #expect(warning.message.contains("rolled back"), "\(warning.message)")
        #expect(await connection.isBroken == false)
    }

    @Test func drainTimeBudgetAlsoCancels() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { _ in
                .partialThenHang(Wire.rowDescription(["g"]) + (1...20).flatMap { Wire.dataRow([String($0)]) })
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        defer { Task { await connection.close() } }
        let result = try await connection.simpleQuery("SELECT g …", limits: RowLimits(maxRows: 5, drainSeconds: 0))
        #expect(result.cancelledAtRowLimit)
        #expect(result.results.last?.rows.count == 5)
    }
}

/// Review finding 8: NOTIFY payloads are bind parameters (never SQL text), and concurrent commands complete in
/// the order they were written, each with its own outcome.
@Suite("Listener")
struct ListenerTests {
    private func makeListener() async throws -> (PostgresClient, PostgresListener, FakeNetwork) {
        let network = FakeNetwork { index in
            let pid = Int32(100 + index)
            return FakePostgresServer(pid: pid) { query in
                if let reply = FakeFacts.reply(query, pid: pid) { return reply }
                if query.contains("bad") { return .bytes(Wire.error("42601", "rejected: \(query)")) }
                return .bytes(Wire.complete(query.hasPrefix("LISTEN") ? "LISTEN" : "SELECT 1"))
            }
        }
        let client = try await PostgresClient.connect(fakeConfiguration(), transportFactory: network.factory)
        return (client, try await PostgresListener.open(client: client), network)
    }

    @Test func notifyPayloadTravelsAsParameters() async throws {
        let (client, listener, network) = try await makeListener()
        defer {
            listener.close()
            Task { await client.close() }
        }
        let payload = "it\\'s'); DROP TABLE x; --"
        try await listener.notify("jobs", payload: payload)
        let server = try #require(network.servers.withLock { $0.last })
        #expect(server.queries.contains("SELECT pg_notify($1, $2)"))
        #expect(!server.queries.contains { $0.contains("DROP TABLE") }, "the payload reached SQL text")
        let bind = try #require(server.packets.first { $0.type == UInt8(ascii: "B") })
        #expect(String(decoding: bind.body, as: UTF8.self).contains(payload))
    }

    @Test func concurrentCommandsGetTheirOwnOutcome() async throws {
        let (client, listener, _) = try await makeListener()
        defer {
            listener.close()
            Task { await client.close() }
        }
        let outcomes = await withTaskGroup(of: (Int, Bool).self) { group in
            for index in 0..<40 {
                group.addTask {
                    do {
                        if index % 2 == 0 {
                            try await listener.listen("ok\(index)")
                        } else if index % 3 == 0 {
                            try await listener.notify("jobs", payload: "\(index)") // parameters: the fake accepts it
                        } else {
                            try await listener.listen("bad\(index)")
                        }
                        return (index, true)
                    } catch {
                        return (index, false)
                    }
                }
            }
            var collected: [Int: Bool] = [:]
            for await (index, succeeded) in group { collected[index] = succeeded }
            return collected
        }
        #expect(outcomes.count == 40)
        for (index, succeeded) in outcomes {
            #expect(succeeded == (index % 2 == 0 || index % 3 == 0), "command \(index) got another command's outcome")
        }
    }
}

@Suite("Metadata lock timeout")
struct LockTimeoutTests {
    /// Review finding 11: the transaction-local lock_timeout travels in the statement's own pipeline (no Sync of
    /// its own), so it ends with the statement and costs no extra round trip.
    @Test func preludeSharesTheStatementsSync() throws {
        let prelude = PostgresConnection.lockTimeoutPrelude(5)
        var types: [Character] = []
        var reader = ByteReader(prelude)
        while !reader.isAtEnd {
            let type = try reader.readUInt8()
            let length = try reader.readInt32()
            _ = try reader.readBytes(Int(length) - 4)
            types.append(Character(Unicode.Scalar(type)))
        }
        #expect(types == ["P", "B", "D", "E"])
        let text = String(decoding: prelude, as: UTF8.self)
        #expect(text.contains("set_config('lock_timeout', $1, true)"))
        #expect(text.contains("5000"))
    }
}
