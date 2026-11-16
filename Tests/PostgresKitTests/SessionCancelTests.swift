import Foundation
import Testing
@testable import PostgresKit
import PostgresWire

/// Waits (up to 5 s) until `condition` holds, instead of guessing with a fixed sleep.
private func waitUntil(_ what: String, _ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw PostgresError(.timeout, "Timed out waiting until \(what)")
}

private func network(connectDelays: [Int: Double] = [:]) -> FakeNetwork {
    FakeNetwork(connectDelays: connectDelays) { index in
        FakePostgresServer(pid: Int32(100 + index)) { query in
            query.contains("long") ? .hang : .bytes(Wire.rows(["x"], [["ok"]]))
        }
    }
}

@Suite("Session cancellation")
struct SessionCancelTests {
    /// Stop pressed while the editor is still connecting used to be ignored (there was no connection to cancel
    /// on yet), so the statement ran anyway.
    @Test func cancelWhileConnectingStopsTheRunBeforeItIsSent() async throws {
        // Connection 1 is the session's own connection: its connect takes 1 s.
        let network = network(connectDelays: [1: 1.0])
        let client = try await PostgresClient.connect(fakeConfiguration(), poolSize: 1, transportFactory: network.factory)
        let session = client.openSession()
        let long = Task { try await session.run("SELECT 'long'") }
        try await waitUntil("the run is connecting") { await session.isBusy }
        #expect(await !session.isStatementRunning)
        await session.cancel()
        await #expect { _ = try await long.value } throws: { ($0 as? PostgresError)?.kind == .cancelled }
        let queries = network.servers.withLock { $0.flatMap(\.queries) }
        #expect(!queries.contains { $0.contains("long") }, "the cancelled statement never reached the server")
        // The request applied to that run only: the next statement runs normally.
        #expect(try await session.run("SELECT 'next'").lastRowSet?.scalar == "ok")
        await session.close()
        await client.close()
    }

    /// A Stop that arrives as soon as the statement starts (before the connection may have registered it)
    /// still stops it.
    @Test func cancelRightAfterTheStatementStartsStopsIt() async throws {
        let network = network()
        let client = try await PostgresClient.connect(fakeConfiguration(), poolSize: 1, transportFactory: network.factory)
        let session = client.openSession()
        _ = try await session.run("SELECT 'warm up'")
        for _ in 0..<5 {
            let long = Task { try await session.run("SELECT 'long'") }
            try await waitUntil("the statement starts") { await session.isStatementRunning }
            await session.cancel()
            await #expect { _ = try await long.value } throws: { ($0 as? PostgresError)?.kind == .cancelled }
        }
        await session.close()
        await client.close()
    }
}
