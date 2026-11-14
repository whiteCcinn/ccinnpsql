import Foundation
import PostgresKit
import Testing

/// TimescaleDB, Citus and PostGIS single-node servers (`scripts/extensions-up.sh`); run with
/// `CCINNPSQL_IT=1 CCINNPSQL_IT_EXTENSIONS=1`.
@Suite("Extension integration", .enabled(if: IT.enabled && ProcessInfo.processInfo.environment["CCINNPSQL_IT_EXTENSIONS"] == "1"),
       .serialized)
struct ExtensionIntegrationTests {
    func client(_ port: Int) async throws -> PostgresClient {
        try await PostgresClient.connect(ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: port), username: "ccinn",
                                                                 password: "ccinn", database: "ccinn", sslMode: .prefer))
    }

    @Test func timescaleHypertables() async throws {
        let client = try await client(15440)
        defer { Task { await client.close() } }
        #expect(client.serverInfo.extensionNamed("timescaledb") != nil)
        #expect(client.serverInfo.productSummary.contains("TimescaleDB"))
        let contents = try await client.schemaContents("public")
        let conditions = try #require(contents.relations.first { $0.name == "conditions" })
        #expect(conditions.isHypertable)
        let info = try await client.hypertableInfo(conditions)
        #expect(info.chunkCount > 1)
        #expect(info.compressionEnabled)
        #expect(info.dimensions.first?.contains("time") == true)
        #expect((info.totalBytes ?? 0) > 0)
        // Chunks live in an internal schema the browser hides by default.
        #expect(SchemaSummary.isSystemSchema("_timescaledb_internal"))
    }

    @Test func citusPlacement() async throws {
        let client = try await client(15441)
        defer { Task { await client.close() } }
        #expect(client.serverInfo.extensionNamed("citus") != nil)
        let contents = try await client.schemaContents("public")
        let events = try #require(contents.relations.first { $0.name == "events" })
        #expect(events.citusPlacement == .distributed)
        #expect(events.distributionColumn == "tenant_id")
        #expect(contents.relations.first { $0.name == "countries" }?.citusPlacement == .reference)
    }

    @Test func postgisColumns() async throws {
        let client = try await client(15442)
        defer { Task { await client.close() } }
        #expect(client.serverInfo.extensionNamed("postgis") != nil)
        let contents = try await client.schemaContents("public")
        // PostGIS functions are extension members and stay out of the routine list.
        #expect(!contents.routines.contains { $0.name.hasPrefix("st_") })
        let places = try #require(contents.relations.first { $0.name == "places" })
        let spatial = try await client.spatialColumns(places)
        #expect(spatial.contains { $0.column == "location" && $0.type == "POINT" && $0.srid == 4326 })
        #expect(spatial.contains { $0.column == "area" && $0.type.contains("geography") })
        let preview = try await client.preview(places)
        #expect(preview.lastRowSet?.columns.first { $0.name == "location" }?.typeName == "geometry")
    }
}
