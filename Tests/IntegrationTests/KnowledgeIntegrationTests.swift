import CcinnPsqlKit
import Foundation
import PostgresKit
import Testing

/// The knowledge base against real servers, on the `kb_demo` schema of `scripts/seed-knowledge.sql`.
@Suite("Knowledge integration", .enabled(if: IT.enabled), .serialized)
struct KnowledgeIntegrationTests {
    private func temporaryStore() -> KnowledgeStore {
        KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-kb-\(UUID().uuidString)", isDirectory: true))
    }

    @Test(arguments: IT.versions)
    func extractionReadsKeysPartitionsViewsAndForeignKeys(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let schema = try await KnowledgeExtractor.extract(schema: "kb_demo", database: nil, from: client)
        let names = schema.tables.map(\.name)
        var expected: Set<String> = ["publisher", "app", "dsp", "dsp_budget", "report_adx_hour", "v_dsp_report", "v_publisher_country", "mv_app_day"]
        if client.serverInfo.version.atLeast(12) { expected.insert("account") }
        #expect(Set(names) == expected, "partitions fold into their parent")
        let report = try #require(schema.tables.first { $0.name == "report_adx_hour" })
        #expect(report.kind == .table && report.keys.primary == ["dt", "hour", "dsp_id", "app_id"] && report.keys.partition == ["dt"])
        #expect(report.comment == "ADX hourly report" && report.columns.first { $0.name == "dsp_id" }?.comment == "DSP")
        #expect(report.columns.first { $0.name == "revenue" }?.type == "numeric(18,6)")
        #expect(schema.tables.first { $0.name == "dsp" }?.keys.unique == [["tenant", "code"]])
        #expect(schema.tables.first { $0.name == "v_dsp_report" }?.kind == .view)
        #expect(schema.tables.first { $0.name == "mv_app_day" }?.kind == .materializedView)
        #expect(schema.tables.first { $0.name == "v_dsp_report" }?.definition?.contains("JOIN") == true)

        let keys = Dictionary(schema.foreignKeys.map { ($0.table + "." + $0.columns.joined(separator: ","), $0) }, uniquingKeysWith: { first, _ in first })
        #expect(keys["publisher.country_code"]?.referencedSchema == "kb_ref" && keys["publisher.country_code"]?.isGuaranteed == true)
        #expect(keys["app.publisher_id"]?.isGuaranteed == false, "NOT VALID")
        #expect(keys["report_adx_hour.app_id"]?.referencedTable == "app" && keys["report_adx_hour.app_id"]?.isGuaranteed == true)
        if client.serverInfo.version.atLeast(18) {
            #expect(keys["dsp_budget.dsp_id"]?.isGuaranteed == false, "NOT ENFORCED")
        } else {
            #expect(keys["dsp_budget.dsp_id"] == nil)
        }
        if client.serverInfo.version.atLeast(12) {
            #expect(schema.foreignKeys.filter { $0.table == "app" && $0.columns == ["account_id"] }.map(\.referencedTable) == ["account"],
                    "one relationship to the partitioned table, none to its partitions")
        }
        #expect(schema.serverVersion?.contains(version) == true)
    }

    // A role whose search path holds the schemas: names and types still print qualified, so lineage and fingerprints
    // do not depend on who refreshed.
    @Test(arguments: IT.versions)
    func catalogTextDoesNotDependOnTheSessionsSearchPath(version: String) async throws {
        let admin = try await IT.client(version)
        defer { Task { await admin.close() } }
        _ = try await admin.records("ALTER ROLE trust_user IN DATABASE ccinn SET search_path = kb_demo, kb_ref, public")
        do {
            let reader = try await PostgresClient.connect(IT.configuration(version, user: "trust_user", password: "", sslMode: .disable), poolSize: 1)
            let fromReader = try await KnowledgeExtractor.extract(schema: "kb_demo", database: nil, from: reader)
            await reader.close()
            let fromAdmin = try await KnowledgeExtractor.extract(schema: "kb_demo", database: nil, from: admin)
            let app = try #require(fromReader.tables.first { $0.name == "app" })
            #expect(app.columns.first { $0.name == "status" }?.type == "kb_demo.app_status")
            let view = try #require(fromReader.tables.first { $0.name == "v_publisher_country" })
            let lineage = KnowledgeRefresher.tableFacts(view, database: "kb_demo", previous: nil, now: Date()).lineage
            #expect(Set(lineage) == [TableReference(database: "kb_ref", table: "country"), TableReference(table: "publisher")], "another schema keeps its name")
            for table in fromReader.tables {
                let other = try #require(fromAdmin.tables.first { $0.name == table.name })
                #expect(KnowledgeRefresher.tableFacts(table, database: "kb_demo", previous: nil, now: Date()).fingerprint
                        == KnowledgeRefresher.tableFacts(other, database: "kb_demo", previous: nil, now: Date()).fingerprint, "\(table.name)")
            }
        } catch {
            _ = try? await admin.records("ALTER ROLE trust_user IN DATABASE ccinn RESET search_path")
            throw error
        }
        _ = try await admin.records("ALTER ROLE trust_user IN DATABASE ccinn RESET search_path")
    }

    @Test(arguments: IT.versions)
    func refreshInfersEverySourceAndScoresByGuarantee(version: String) async throws {
        let client = try await IT.client(version)
        defer { Task { await client.close() } }
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "pg://127.0.0.1:\(IT.port(version))"), catalog: "ccinn", database: "kb_demo")
        let history = [QueryHistoryEntry(sql: "SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-19'", database: "ccinn",
                                         durationMilliseconds: 3)]
        let report = try await KnowledgeService.refresh(key, source: client, store: store, history: history, infer: KnowledgeInference.machineRelationships,
                                                        now: Date())
        #expect(report.tables.total == (client.serverInfo.version.atLeast(12) ? 9 : 8))
        let knowledge = try #require(try store.database(key))
        func relationship(_ from: String, _ to: String) -> Relationship? {
            knowledge.relationships.first { "\($0.from.table).\($0.from.columns.joined(separator: ","))" == from
                && "\($0.to.database.map { $0 + "." } ?? "")\($0.to.table).\($0.to.columns.joined(separator: ","))" == to }
        }
        let toCountry = try #require(relationship("publisher.country_code", "kb_ref.country.code"))
        #expect(RelationshipConfidence.score(toCountry) == 100)
        let toPublisher = try #require(relationship("app.publisher_id", "publisher.id"))
        #expect(RelationshipConfidence.score(toPublisher) < 100 && toPublisher.evidence.contains { $0.source == .declared }, "NOT VALID scores below a fact")
        let toDSP = try #require(relationship("report_adx_hour.dsp_id", "dsp.id"))
        let sources = Set(toDSP.evidence.map(\.source))
        #expect(sources.isSuperset(of: [.definition, .history, .naming]), "\(sources)")
        #expect(toDSP.kind == .manyToOne)
        let lineage = knowledge.relationships.filter { $0.kind == .lineage && $0.from.table == "mv_app_day" }
        #expect(Set(lineage.map(\.to.table)) == ["report_adx_hour", "app"])
        #expect(try store.index().clusters.first { $0.key == key.cluster }?.serverIdentifier != nil || !client.serverInfo.isSuperuser,
                "a superuser can read system_identifier")
    }

    @Test(arguments: IT.versions)
    func visibilityFollowsTheRolesPrivileges(version: String) async throws {
        let admin = try await IT.client(version)
        defer { Task { await admin.close() } }
        _ = try await admin.records("REVOKE ALL ON SCHEMA kb_demo FROM trust_user")
        _ = try await admin.records("REVOKE ALL ON ALL TABLES IN SCHEMA kb_demo FROM trust_user")
        let restricted = try await PostgresClient.connect(IT.configuration(version, user: "trust_user", password: "", sslMode: .disable), poolSize: 1)
        defer { Task { await restricted.close() } }
        #expect(try await KnowledgeMCP.liveVisibility(restricted, nil, "kb_demo") == nil, "no USAGE on the schema")
        _ = try await admin.records("GRANT USAGE ON SCHEMA kb_demo TO trust_user")
        _ = try await admin.records("GRANT SELECT ON kb_demo.dsp TO trust_user")
        _ = try await admin.records("GRANT SELECT (dt, hour) ON kb_demo.report_adx_hour TO trust_user")
        let visibility = try #require(try await KnowledgeMCP.liveVisibility(restricted, nil, "kb_demo"))
        #expect(visibility.tables == ["dsp", "report_adx_hour"], "a table with one readable column counts")
        #expect(visibility.columns["dsp"] == .some(nil), "SELECT on the table: every column")
        #expect(visibility.contains("report_adx_hour", column: "dt") && visibility.contains("report_adx_hour", column: "hour"))
        #expect(!visibility.contains("report_adx_hour", column: "revenue") && !visibility.contains("report_adx_hour", column: "dsp_id"),
                "column grants are honoured: the catalog lists every column, the privileges do not")
        #expect(try await KnowledgeMCP.liveVisibility(restricted, nil, "pg_catalog") == nil)

        // Knowledge an administrator built, as the restricted role's AI session sees it.
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let key = DatabaseKey(cluster: ClusterKey(rawValue: "pg://127.0.0.1:\(IT.port(version))"), catalog: "ccinn", database: "kb_demo")
        _ = try await KnowledgeService.refresh(key, source: admin, store: store, history: [], infer: KnowledgeInference.machineRelationships, now: Date())
        let seen = KnowledgeMCP.filter(try #require(try store.database(key)), visibility: visibility)
        #expect(seen.table(named: "report_adx_hour")?.columns.map(\.name) == ["dt", "hour"])
        #expect(seen.table(named: "report_adx_hour")?.keys.primary.isEmpty == true, "the primary key names hidden columns")
        #expect(!seen.relationships.contains { $0.from.table == "report_adx_hour" }, "its foreign keys start at hidden columns")
        #expect(Set(seen.tables.map(\.name)) == ["dsp", "report_adx_hour"])
        _ = try await admin.records("REVOKE ALL ON ALL TABLES IN SCHEMA kb_demo FROM trust_user")
        _ = try await admin.records("REVOKE SELECT (dt, hour) ON kb_demo.report_adx_hour FROM trust_user")
        _ = try await admin.records("REVOKE ALL ON SCHEMA kb_demo FROM trust_user")
    }
}
