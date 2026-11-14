import Foundation
import Testing
@testable import PostgresKit
import PostgresWire

func fakeConfiguration(password: String = "secret", cleartext: Bool = false) -> ConnectionConfiguration {
    ConnectionConfiguration(endpoint: Endpoint(host: "db.example", port: 5432), username: "app", password: password, database: "app",
                            connectTimeout: 5, sslMode: .disable, allowCleartextPassword: cleartext)
}

@Suite("Connection with a fake server")
struct ConnectionTests {
    @Test func startupStoresKeyAndParameters() async throws {
        let network = FakeNetwork()
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        #expect(connection.backendKey?.processID == 100)
        #expect(connection.startupParameters["server_version"] == "17.2")
        #expect(connection.remoteEndpoint == Endpoint(host: "10.0.0.7", port: 5432))
        let startup = try #require(network.servers.withLock { $0.first }?.packets.first)
        var reader = ByteReader(startup.body)
        #expect(try reader.readInt32() == 196_608)
        #expect(try reader.readCString() == "user")
        #expect(try reader.readCString() == "app")
    }

    @Test func clearTextNeedsOptIn() async throws {
        let network = FakeNetwork { _ in FakePostgresServer(auth: .cleartext) }
        do {
            _ = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
            Issue.record("clear text accepted without opt-in")
        } catch let error as PostgresError {
            #expect(error.kind == .authentication)
        }
        // The password was never sent.
        #expect(network.servers.withLock { $0.first }?.packets.contains { $0.type == UInt8(ascii: "p") } == false)
        let allowed = FakeNetwork { _ in FakePostgresServer(auth: .cleartext) }
        let connection = try await PostgresConnection.connect(fakeConfiguration(cleartext: true), transportFactory: allowed.factory)
        await connection.close()
    }

    @Test func scramWithoutServerSignatureIsRejected() async throws {
        let network = FakeNetwork { _ in FakePostgresServer(auth: .scramWithoutFinal) }
        do {
            _ = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
            Issue.record("impersonating server accepted")
        } catch let error as PostgresError {
            #expect(error.kind == .authentication)
            #expect(error.message.contains("SCRAM"))
        }
    }

    @Test func authenticationFailureIsReported() async throws {
        let network = FakeNetwork { _ in FakePostgresServer(auth: .reject) }
        do {
            _ = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
            Issue.record("expected failure")
        } catch let error as PostgresError {
            #expect(error.kind == .authentication)
            #expect(error.sqlState == "28P01")
        }
    }

    @Test func connectFromCancelledTaskFailsFast() async throws {
        let network = FakeNetwork()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        }
        let started = ContinuousClock.now
        await #expect(throws: PostgresError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(network.servers.withLock { $0.isEmpty })
    }

    @Test func queriesAndServerErrorsKeepTheConnection() async throws {
        let network = FakeNetwork { _ in
            FakePostgresServer { query in
                query.contains("boom") ? .bytes(Wire.error("42P01", "relation \"boom\" does not exist")) : .bytes(Wire.rows(["a"], [["1"], [nil]]))
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let result = try await connection.simpleQuery("SELECT a FROM t")
        #expect(result.lastRowSet?.rows == [["1"], [nil]])
        do {
            _ = try await connection.extendedQuery("SELECT * FROM boom")
            Issue.record("expected error")
        } catch let error as PostgresError {
            #expect(error.kind == .server)
            #expect(error.sqlState == "42P01")
        }
        #expect(await connection.isBroken == false)
        #expect(try await connection.extendedQuery("SELECT a").lastRowSet?.rows.count == 2)
    }

    @Test func overlappingCommandsFailFast() async throws {
        let network = FakeNetwork { _ in FakePostgresServer { _ in .hang } }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let first = Task { try await connection.extendedQuery("SELECT pg_sleep(60)") }
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await connection.extendedQuery("SELECT 1")
            Issue.record("expected busy")
        } catch let error as PostgresError {
            #expect(error.kind == .busy)
        }
        first.cancel()
        _ = try? await first.value
    }

    @Test func cancelGoesToTheResolvedAddressAndKeepsTheConnection() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in query.contains("sleep") ? .hang : .bytes(Wire.rows(["x"], [["ok"]])) }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let task = Task { try await connection.extendedQuery("SELECT pg_sleep(60)") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(network.cancelEndpoints.withLock { $0 } == [Endpoint(host: "10.0.0.7", port: 5432)])
        #expect(await connection.isBroken == false)
        #expect(try await connection.extendedQuery("SELECT x").lastRowSet?.scalar == "ok")
    }

    @Test func noCancelForIdleConnections() async throws {
        let network = FakeNetwork { _ in FakePostgresServer { _ in .bytes(Wire.rows(["x"], [["1"]])) } }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        _ = try await connection.extendedQuery("SELECT 1")
        connection.cancelRunningStatement() // nothing is running: must not send anything
        try await Task.sleep(for: .milliseconds(100))
        #expect(network.cancelEndpoints.withLock { $0.isEmpty })
        #expect(network.servers.withLock { $0.first }?.cancelCount == 0)
    }

    @Test func nextStatementWaitsForAnInFlightCancel() async throws {
        // The cancel takes 300 ms to be delivered; the next statement must not start before that.
        let network = FakeNetwork(cancelDelay: 0.3) { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in query.contains("sleep") ? .hang : .bytes(Wire.rows(["x"], [["ok"]])) }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let task = Task { try await connection.extendedQuery("SELECT pg_sleep(60)") }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        _ = try? await task.value
        #expect(network.servers.withLock { $0.first }?.cancelCount == 1)
        let next = try await connection.extendedQuery("SELECT x")
        #expect(next.lastRowSet?.scalar == "ok")
    }

    @Test func unansweredCancelClosesTheSocketAfterGrace() async throws {
        // A server that ignores the cancel (e.g. a pooler that lost it): the socket is closed after the grace period.
        let network = FakeNetwork { _ in FakePostgresServer(pid: 999, ignoresCancel: true) { _ in .hang } }
        var configuration = fakeConfiguration()
        configuration.cancelGraceSeconds = 0.3
        let connection = try await PostgresConnection.connect(configuration, transportFactory: network.factory)
        let task = Task { try await connection.extendedQuery("SELECT 1") }
        try await Task.sleep(for: .milliseconds(50))
        let started = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(await connection.isBroken)
        #expect(network.servers.withLock { $0.first }?.isClosed == true)
    }
}

@Suite("Pool")
struct PoolTests {
    @Test func reusesConnectionsAndDropsOnesLeftInTransaction() async throws {
        let network = FakeNetwork { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in
                query.hasPrefix("BEGIN") ? .raw(Wire.complete("BEGIN") + Wire.ready("T")) : .bytes(Wire.complete("SELECT 0"))
            }
        }
        let configuration = fakeConfiguration()
        let pool = ConnectionPool(maxSize: 2) { try await PostgresConnection.connect(configuration, transportFactory: network.factory) }
        let first = try await pool.withConnection { $0.backendKey?.processID }
        let second = try await pool.withConnection { $0.backendKey?.processID }
        #expect(first == second)
        #expect(await pool.statistics.open == 1)
        // A caller that leaves a transaction open: the connection is closed instead of returned.
        let leaked = try await pool.withConnection { connection -> Int32? in
            _ = try await connection.simpleQuery("BEGIN")
            return connection.backendKey?.processID
        }
        #expect(leaked == first)
        #expect(await pool.statistics.open == 0)
        let fresh = try await pool.withConnection { $0.backendKey?.processID }
        #expect(fresh != first)
        await pool.close()
    }

    @Test func cancelledWaiterDoesNotLeakASlot() async throws {
        let network = FakeNetwork { _ in FakePostgresServer { _ in .bytes(Wire.complete("SELECT 0")) } }
        let configuration = fakeConfiguration()
        let pool = ConnectionPool(maxSize: 1) { try await PostgresConnection.connect(configuration, transportFactory: network.factory) }
        let held = try await pool.checkout()
        let waiter = Task { try await pool.checkout() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: PostgresError.self) { _ = try await waiter.value }
        await pool.checkin(held)
        let again = try await pool.checkout()
        await pool.checkin(again)
        #expect(await pool.statistics.open == 1)
        await pool.close()
    }

    @Test func cancelledCallerDoesNotOpenConnections() async throws {
        let network = FakeNetwork()
        let configuration = fakeConfiguration()
        let pool = ConnectionPool(maxSize: 2) { try await PostgresConnection.connect(configuration, transportFactory: network.factory) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await pool.checkout()
        }
        await #expect(throws: PostgresError.self) { _ = try await task.value }
        #expect(await pool.statistics.open == 0)
        await pool.close()
    }
}
