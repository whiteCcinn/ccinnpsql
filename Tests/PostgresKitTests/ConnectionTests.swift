import Foundation
import os
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

@Suite("Cancel coordinator")
struct CancelCoordinatorTests {
    /// A sender that blocks until the test opens it.
    final class GatedSender: Sendable {
        let gate = OneShotGate()
        let calls = OSAllocatedUnfairLockBox()

        func send() async {
            calls.increment()
            await withCheckedContinuation { gate.arm($0) }
        }
    }

    @Test func cancelForAFinishedGenerationSendsNothing() async throws {
        let sender = GatedSender()
        sender.gate.open()
        let coordinator = CancelCoordinator(graceSeconds: 1, sender: { await sender.send() }, forceClose: {})
        let generation = coordinator.begin()
        coordinator.end(generation)
        #expect(coordinator.cancel(generation: generation, reason: .task) == false)
        let next = coordinator.begin()
        #expect(coordinator.cancel(generation: generation, reason: .task) == false) // stale generation, newer run
        #expect(coordinator.cancel(generation: next, reason: .task))
        #expect(coordinator.cancel(generation: next, reason: .task) == false) // once per generation
        try await Task.sleep(for: .milliseconds(50))
        #expect(sender.calls.value == 1)
    }

    @Test func nextRunWaitsUntilTheCancelIsDelivered() async throws {
        let sender = GatedSender()
        let coordinator = CancelCoordinator(graceSeconds: 5, sender: { await sender.send() }, forceClose: {})
        let generation = coordinator.begin()
        #expect(coordinator.cancel(generation: generation, reason: .task))
        coordinator.end(generation) // the statement finished before the cancel reached the server
        let finished = OSAllocatedUnfairLockBox()
        let waiter = Task {
            await coordinator.waitForPendingDelivery()
            finished.increment()
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(finished.value == 0, "must not start while the cancel is in flight")
        sender.gate.open()
        await waiter.value
        #expect(finished.value == 1)
    }

    @Test func forceCloseAfterGraceWhenTheStatementKeepsRunning() async throws {
        let closed = OSAllocatedUnfairLockBox()
        let coordinator = CancelCoordinator(graceSeconds: 0.1, sender: {}, forceClose: { closed.increment() })
        let generation = coordinator.begin()
        coordinator.cancel(generation: generation, reason: .task)
        try await Task.sleep(for: .milliseconds(400))
        #expect(closed.value == 1)

        // A statement that stops within the grace period keeps its socket.
        let stopping = CancelCoordinator(graceSeconds: 0.2, sender: {}, forceClose: { closed.increment() })
        let second = stopping.begin()
        stopping.cancel(generation: second, reason: .task)
        stopping.end(second)
        try await Task.sleep(for: .milliseconds(400))
        #expect(closed.value == 1)
    }

    @Test func cancelledWaiterReturnsPromptly() async throws {
        let sender = GatedSender()
        let coordinator = CancelCoordinator(graceSeconds: 5, sender: { await sender.send() }, forceClose: {})
        let generation = coordinator.begin()
        coordinator.cancel(generation: generation, reason: .task)
        coordinator.end(generation)
        let started = ContinuousClock.now
        let waiter = Task { await coordinator.waitForPendingDelivery() }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await waiter.value
        #expect(ContinuousClock.now - started < .seconds(1))
        sender.gate.open()
    }
}

@Suite("Late cancel and statement names")
struct LateCancelTests {
    @Test func lateCancelNeverHitsTheNextStatement() async throws {
        // The first statement completes at 100 ms; its cancel (sent at 50 ms) takes 400 ms to arrive. The next
        // statement is issued at once and must reach the server only after the cancel was delivered (when the
        // server is idle and ignores it), so it succeeds.
        let network = FakeNetwork(cancelDelay: 0.4) { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in
                query.contains("slow") ? .delayed(Wire.rows(["x"], [["first"]]), seconds: 0.1) : .bytes(Wire.rows(["x"], [["second"]]))
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let server = try #require(network.servers.withLock { $0.first })
        let first = Task { try await connection.extendedQuery("SELECT slow") }
        try await Task.sleep(for: .milliseconds(50))
        connection.cancelRunningStatement()
        _ = try? await first.value
        let next = try await connection.extendedQuery("SELECT next")
        #expect(next.lastRowSet?.scalar == "second")
        let cancelAt = try #require(server.cancelArrivals.first)
        let nextAt = try #require(server.queryArrivals.last)
        #expect(nextAt >= cancelAt, "the next statement was sent before the late cancel arrived")
        #expect(server.idleCancels == 1)
    }

    @Test func taskCancelledWhileWaitingForACancelKeepsTheConnectionUsable() async throws {
        let network = FakeNetwork(cancelDelay: 1.0) { index in
            FakePostgresServer(pid: Int32(100 + index)) { query in
                query.contains("slow") ? .delayed(Wire.rows(["x"], [["first"]]), seconds: 0.1) : .bytes(Wire.rows(["x"], [["ok"]]))
            }
        }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        let first = Task { try await connection.extendedQuery("SELECT slow") }
        try await Task.sleep(for: .milliseconds(50))
        connection.cancelRunningStatement()
        _ = try? await first.value
        let started = ContinuousClock.now
        let second = Task { try await connection.extendedQuery("SELECT waiting") }
        try await Task.sleep(for: .milliseconds(100))
        second.cancel()
        do {
            _ = try await second.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .milliseconds(800))
        #expect(await connection.isIdle)
        #expect(try await connection.extendedQuery("SELECT after").lastRowSet?.scalar == "ok")
    }

    @Test func extendedQueriesUseTheUnnamedStatementAndPortal() async throws {
        // Required for PgBouncer transaction pooling without prepared-statement support.
        let network = FakeNetwork { _ in FakePostgresServer { _ in .bytes(Wire.rows(["x"], [["1"]])) } }
        let connection = try await PostgresConnection.connect(fakeConfiguration(), transportFactory: network.factory)
        _ = try await connection.extendedQuery("SELECT $1::int", parameters: [.text("1")])
        _ = try await connection.extendedQuery("SELECT 2")
        let packets = try #require(network.servers.withLock { $0.first }).packets
        let parses = packets.filter { $0.type == UInt8(ascii: "P") }
        let binds = packets.filter { $0.type == UInt8(ascii: "B") }
        let describes = packets.filter { $0.type == UInt8(ascii: "D") }
        let executes = packets.filter { $0.type == UInt8(ascii: "E") }
        #expect(parses.count == 2 && binds.count >= 1)
        #expect(parses.allSatisfy { $0.body.first == 0 }, "statement name must be empty")
        #expect(binds.allSatisfy { Array($0.body.prefix(2)) == [0, 0] }, "portal and statement names must be empty")
        #expect(describes.allSatisfy { $0.body.count == 2 && $0.body[1] == 0 }, "Describe targets the unnamed portal")
        #expect(executes.allSatisfy { $0.body.first == 0 })
        #expect(!packets.contains { $0.type == UInt8(ascii: "C") }, "no Close of named statements")
    }
}

/// A tiny thread-safe counter for tests.
final class OSAllocatedUnfairLockBox: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    func increment() { lock.withLock { $0 += 1 } }
    var value: Int { lock.withLock { $0 } }
}
