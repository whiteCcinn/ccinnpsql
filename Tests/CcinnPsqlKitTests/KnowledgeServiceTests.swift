import Foundation
import PostgresKit
import Testing
@testable import CcinnPsqlKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "pg://fe:9030"), catalog: "ads", database: "adx")

private func temporaryStore() -> KnowledgeStore {
    KnowledgeStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ccinn-kb-\(UUID().uuidString)", isDirectory: true))
}

private func sample() -> DatabaseKnowledge {
    var knowledge = DatabaseKnowledge(key: key)
    knowledge.tables = [TableFacts(name: "report", kind: .table, columns: [ColumnFacts(name: "dsp_id", type: "bigint")], fingerprint: "f1", state: .fresh, firstSeen: now),
                        TableFacts(name: "dsp", kind: .table, columns: [ColumnFacts(name: "id", type: "bigint", isKey: true)], fingerprint: "f2", state: .fresh, firstSeen: now)]
    knowledge.relationships = [Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                            evidence: [Evidence(source: .naming, score: 55, at: now)], fingerprints: ["report": "old", "dsp": "f2"])]
    knowledge.notes = [Note(id: "n1", table: "report", column: nil, kind: .usage, text: "x", evidence: [], by: "ai:codex", at: now, fingerprint: nil)]
    return knowledge
}

@Suite("Knowledge service")
struct KnowledgeServiceTests {
    @Test func theUsersVerdictIsEvidenceThatWins() throws {
        var knowledge = sample()
        let id = knowledge.relationships[0].id
        try KnowledgeService.decide(id, accept: true, in: &knowledge, now: now)
        #expect(knowledge.relationships[0].status == .confirmed)
        #expect(knowledge.relationships[0].evidence.filter { $0.source == .user }.count == 1)
        #expect(knowledge.relationships[0].fingerprints == ["report": "f1", "dsp": "f2"], "confirming re-binds it to the current structure")
        try KnowledgeService.decide(id, accept: false, in: &knowledge, now: now)
        #expect(knowledge.relationships[0].status == .rejected)
        #expect(knowledge.relationships[0].evidence.filter { $0.source == .user }.map(\.verdict) == [.reject], "one user verdict, the latest")
        #expect(throws: KnowledgeService.Failure.self) { try KnowledgeService.decide("nope", accept: true, in: &knowledge, now: now) }
    }

    @Test func theUserDeletesAnythingWithATombstone() throws {
        var knowledge = sample()
        let relationship = knowledge.relationships[0].id
        try KnowledgeService.delete(ids: ["n1", relationship], in: &knowledge, now: now)
        #expect(knowledge.notes.isEmpty && knowledge.relationships.isEmpty)
        #expect(Set(knowledge.tombstones.map(\.id)) == ["n1", relationship])
        #expect(knowledge.tombstones.allSatisfy { $0.by == "user" })
    }

    @Test func projectsLinkUnlinkAndRemap() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent("code/adx", isDirectory: true)
        let moved = home.appendingPathComponent("work/adx", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let id = try KnowledgeService.linkProject(path: project.path, to: key, store: store, home: home, now: now)
        var index = try store.index()
        #expect(index.projects.map(\.path) == ["~/code/adx"] && index.projects.first?.addedBy == "user")
        #expect(index.links.map(\.database) == [key.fileID])
        #expect(index.databases.map(\.key) == [key])

        try KnowledgeService.remapProject(id: id, to: moved.path, store: store, home: home)
        index = try store.index()
        #expect(index.projects.map(\.path) == ["~/work/adx"])
        #expect(index.links.count == 1, "links follow the project")

        try KnowledgeService.unlinkProject(id: id, from: key, store: store)
        #expect(try store.index().links.isEmpty)
    }

    @Test func deletingADatabasesKnowledgeRemovesItsFileAndLinks() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.updateDatabase(key) { $0 = sample() }
        try store.updateIndex { $0.links.append(KnowledgeIndex.Link(project: "p1", database: key.fileID, addedAt: now, addedBy: "user")) }
        try store.removeDatabase(key)
        #expect(try store.database(key) == nil)
        let index = try store.index()
        #expect(index.databases.isEmpty && index.links.isEmpty)
        #expect(index.tombstones.map(\.id) == [key.fileID])
    }

    // The app and `mcp` refresh through the same pipeline.
    @Test func refreshExtractsInfersAndSaves() async throws {
        struct Source: KnowledgeSchemaSource {
            let knowledgeServerVersion: String? = "PostgreSQL 18.1"
            func knowledgeSchema(_ schema: String, database: String?) async throws -> KnowledgeSchemaRows {
                KnowledgeSchemaRows(relations: [KnowledgeRelationRow(name: "report", relkind: "r"), KnowledgeRelationRow(name: "dsp", relkind: "r")],
                                    columns: ["report": [KnowledgeColumnRow(table: "report", name: "dsp_id", type: "bigint", isNullable: true)],
                                              "dsp": [KnowledgeColumnRow(table: "dsp", name: "id", type: "bigint", isNullable: false)]],
                                    constraints: [KnowledgeConstraintRow(table: "dsp", kind: .primary, columns: ["id"])])
            }
            func knowledgeServerIdentifier(database: String?) async -> String? { "7312345678901234567" }
        }
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let infer: KnowledgeToolSettings.Inference = { (input: KnowledgeInferenceInput) -> [Relationship] in
            #expect(input.knowledge.tables.map(\.name) == ["dsp", "report"], "inference sees this extraction's tables")
            return [Relationship(from: .init(table: "report", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                 evidence: [Evidence(source: .naming, score: 55, at: input.now)])]
        }
        let report = try await KnowledgeService.refresh(key, source: Source(), store: store, history: [], infer: infer, now: now)
        #expect(report.tables.total == 2 && report.relationships.added == 1)
        #expect(try store.database(key)?.relationships.first?.fingerprints["report"] != nil)
    }
}

@Suite("Knowledge inference wiring")
struct KnowledgeInferenceWiringTests {
    @Test func everyMachineSourceContributes() throws {
        func column(_ name: String, key: Bool = false) -> ColumnFacts {
            ColumnFacts(name: name, type: "bigint", isKey: key, isNullable: !key)
        }
        let schema = ExtractedSchema(database: "adx", serverVersion: nil, serverIdentifier: nil, tables: [
            ExtractedTable(name: "report_adx_hour", kind: .table, columns: [column("dsp_id"), column("app_id")]),
            ExtractedTable(name: "dsp", kind: .table, keys: TableFacts.Keys(primary: ["id"]), columns: [column("id", key: true)]),
            ExtractedTable(name: "app", kind: .table, keys: TableFacts.Keys(primary: ["id"]), columns: [column("id", key: true)]),
            ExtractedTable(name: "v_report", kind: .view, columns: [column("dsp_id")],
                           definition: "SELECT r.dsp_id FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id"),
        ], foreignKeys: [ExtractedForeignKey(table: "report_adx_hour", columns: ["app_id"], referencedSchema: "adx", referencedTable: "app",
                                             referencedColumns: ["id"], isGuaranteed: true)])
        var knowledge = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        KnowledgeRefresher.updateTables(schema, in: &knowledge, now: now, report: &report)
        let history = [QueryHistoryEntry(id: UUID(), sql: "SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-19'",
                                         database: "ads", executedAt: now, durationMilliseconds: 10, rowCount: 1, affectedRows: nil, errorMessage: nil)]
        let machine = KnowledgeInference.machineRelationships(KnowledgeInferenceInput(schema: schema, knowledge: knowledge, history: history, now: now))
        let sources = Set(machine.flatMap { $0.evidence.map(\.source) })
        #expect(sources.isSuperset(of: [.declared, .naming, .history, .definition]), "\(sources)")
        let declared = try #require(machine.first { $0.evidence.contains { $0.source == .declared } })
        #expect(declared.from.table == "report_adx_hour" && declared.to.table == "app" && declared.to.columns == ["id"])
    }
}

@Suite("Join extraction from server-printed definitions")
struct ServerPrintedDefinitionTests {
    // pg_get_viewdef(oid, true) prints aliases and qualified columns like this.
    @Test func prettyPrintedViewDefinitions() {
        let definition = """
         SELECT r.dt,
            d.name AS dsp_name
           FROM (kb_demo.report_adx_hour r
             JOIN kb_demo.dsp d ON ((r.dsp_id = d.id)))
          GROUP BY r.dt, d.name;
        """
        let joins = SQLJoinExtractor.joins(in: definition) { _ in nil }
        #expect(joins.count == 1)
        let pair = joins.first
        let tables = Set([pair?.left.table, pair?.right.table].compactMap { $0 })
        #expect(tables == ["report_adx_hour", "dsp"])
    }
}
