import Foundation
import PostgresKit
import Testing

/// Guards against pathological decoding costs (buffer compaction, per-row allocations) on large results.
@Suite("Throughput", .enabled(if: IT.enabled), .serialized)
struct ThroughputIntegrationTests {
    @Test func largeResultsDecodeQuickly() async throws {
        let version = IT.versions.last ?? "17"
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        let sql = "SELECT g AS id, md5(g::text) AS hash, now() AS at, g * 1.5 AS amount, (g % 2 = 0) AS even FROM generate_series(1, 200000) g"
        let clock = ContinuousClock()
        let started = clock.now
        let text = try await connection.extendedQuery(sql, limits: RowLimits(maxRows: 300_000))
        let textElapsed = clock.now - started
        #expect(text.lastRowSet?.rows.count == 200_000)
        let binaryStarted = clock.now
        let binary = try await connection.extendedQuery(sql, resultFormat: .binaryWhereSupported, limits: RowLimits(maxRows: 300_000))
        let binaryElapsed = clock.now - binaryStarted
        #expect(binary.lastRowSet?.rows.count == 200_000)
        #expect(textElapsed < .seconds(10), "text decoding took \(textElapsed)")
        #expect(binaryElapsed < .seconds(15), "binary decoding took \(binaryElapsed)")
        print("throughput: 200k rows text \(textElapsed), binary \(binaryElapsed)")
    }
}
