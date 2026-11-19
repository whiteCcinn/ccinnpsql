import Foundation
import PostgresKit
import Testing
@testable import CcinnPsqlKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let later = Date(timeIntervalSince1970: 1_800_086_400)
private let key = DatabaseKey(cluster: ClusterKey(rawValue: "pg://fe:9030"), catalog: "ads", database: "adx")

/// A relation as `KnowledgeExtractor.build` makes it from catalog rows.
private func relation(_ name: String, _ relkind: String = "r", comment: String? = nil, partitionKey: String? = nil, definition: String? = nil)
    -> KnowledgeRelationRow {
    KnowledgeRelationRow(name: name, relkind: relkind, comment: comment, partitionKey: partitionKey, definition: definition)
}

private func column(_ table: String, _ name: String, _ type: String, nullable: Bool = true, comment: String? = nil) -> KnowledgeColumnRow {
    KnowledgeColumnRow(table: table, name: name, type: type, isNullable: nullable, comment: comment)
}

private func rows(dspIDType: String = "bigint", reportComment: String = "hourly report", viewDefinition: String? = nil,
                  extra: [(KnowledgeRelationRow, [KnowledgeColumnRow], [KnowledgeConstraintRow])] = [], dropping: Set<String> = []) -> KnowledgeSchemaRows {
    var relations = [
        relation("report_adx_hour", "p", comment: reportComment, partitionKey: "RANGE (dt)"),
        relation("dsp"),
        relation("v_dsp_report", "v",
                 definition: viewDefinition ?? "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt > '2026-01-01'"),
    ]
    var columns: [String: [KnowledgeColumnRow]] = [
        "report_adx_hour": [column("report_adx_hour", "dt", "date", nullable: false), column("report_adx_hour", "hour", "smallint", nullable: false),
                            column("report_adx_hour", "dsp_id", dspIDType, nullable: false, comment: "DSP"),
                            column("report_adx_hour", "dsp_request", "bigint")],
        "dsp": [column("dsp", "id", "bigint", nullable: false), column("dsp", "name", "character varying(64)")],
        "v_dsp_report": [column("v_dsp_report", "dt", "date"), column("v_dsp_report", "dsp_name", "character varying(64)")],
    ]
    var constraints = [
        KnowledgeConstraintRow(table: "report_adx_hour", kind: .primary, columns: ["dt", "hour", "dsp_id"]),
        KnowledgeConstraintRow(table: "dsp", kind: .primary, columns: ["id"]),
    ]
    for (relation, extraColumns, extraConstraints) in extra {
        relations.append(relation)
        columns[relation.name] = extraColumns
        constraints += extraConstraints
    }
    relations.removeAll { dropping.contains($0.name) }
    return KnowledgeSchemaRows(relations: relations, columns: columns, constraints: constraints)
}

private func schema(dspIDType: String = "bigint", reportComment: String = "hourly report", viewDefinition: String? = nil,
                    extra: [(KnowledgeRelationRow, [KnowledgeColumnRow], [KnowledgeConstraintRow])] = [], dropping: Set<String> = []) -> ExtractedSchema {
    KnowledgeExtractor.build(schema: "adx", rows: rows(dspIDType: dspIDType, reportComment: reportComment, viewDefinition: viewDefinition, extra: extra,
                                                     dropping: dropping),
                             serverVersion: "PostgreSQL 18.1", serverIdentifier: nil)
}

@Suite("Schema fingerprints")
struct SchemaFingerprintTests {
    private func facts(_ schema: ExtractedSchema, _ name: String) throws -> TableFacts {
        let table = try #require(schema.tables.first { $0.name == name })
        return KnowledgeRefresher.tableFacts(table, database: "adx", previous: nil, now: now)
    }

    @Test func factsFollowTheCatalogInColumnOrder() throws {
        let report = try facts(schema(), "report_adx_hour")
        #expect(report.columns.map(\.name) == ["dt", "hour", "dsp_id", "dsp_request"])
        #expect(report.kind == .table && report.model == nil)
        #expect(report.keys.primary == ["dt", "hour", "dsp_id"])
        #expect(report.columns.filter(\.isKey).map(\.name) == ["dt", "hour", "dsp_id"])
        #expect(report.keys.partition == ["dt"])
        #expect(report.columns.last?.isNullable == true && report.columns.first?.isNullable == false)
        #expect(report.state == .new && report.firstSeen == now)
        let view = try facts(schema(), "v_dsp_report")
        #expect(view.kind == .view)
        #expect(view.lineage == [TableReference(table: "dsp"), TableReference(table: "report_adx_hour")])
    }

    @Test func commentsDoNotChangeTheStructureFingerprint() throws {
        let original = try facts(schema(), "report_adx_hour")
        let recommented = try facts(schema(reportComment: "per hour"), "report_adx_hour")
        #expect(original.fingerprint == recommented.fingerprint)
        #expect(original.commentFingerprint != recommented.commentFingerprint)
        let retyped = try facts(schema(dspIDType: "varchar(32)"), "report_adx_hour")
        #expect(original.fingerprint != retyped.fingerprint)
    }

    @Test func literalOnlyChangesInAViewDefinitionKeepTheFingerprint() throws {
        let original = try facts(schema(), "v_dsp_report")
        let otherDate = try facts(schema(viewDefinition: "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt > '2026-06-01'"),
                                  "v_dsp_report")
        #expect(original.fingerprint == otherDate.fingerprint)
        let otherJoin = try facts(schema(viewDefinition: "SELECT r.dt, d.name AS dsp_name FROM report_adx_hour r JOIN dsp d ON r.hour = d.id"), "v_dsp_report")
        #expect(original.fingerprint != otherJoin.fingerprint)
    }
}

@Suite("Knowledge refresh")
struct KnowledgeRefreshTests {
    private func refreshed(_ schemas: [ExtractedSchema], machine: [[Relationship]] = []) -> (DatabaseKnowledge, KnowledgeRefresher.Report) {
        var knowledge = DatabaseKnowledge(key: key)
        var report = KnowledgeRefresher.Report()
        for (index, schema) in schemas.enumerated() {
            report = KnowledgeRefresher.apply(schema, machineRelationships: index < machine.count ? machine[index] : [], to: &knowledge,
                                              now: index == 0 ? now : later)
        }
        return (knowledge, report)
    }

    @Test func tableStatesAcrossRefreshes() {
        let renamed = (relation("dsp_v2"), [column("dsp_v2", "id", "bigint", nullable: false), column("dsp_v2", "name", "character varying(64)")],
                       [KnowledgeConstraintRow(table: "dsp_v2", kind: .primary, columns: ["id"])])
        let (knowledge, report) = refreshed([schema(), schema(dspIDType: "varchar(32)", extra: [renamed], dropping: ["dsp"])])
        #expect(knowledge.table(named: "report_adx_hour")?.state == .changed)
        #expect(knowledge.table(named: "report_adx_hour")?.changedAt == later)
        #expect(knowledge.table(named: "dsp")?.state == .dropped, "kept until the user prunes it")
        #expect(knowledge.table(named: "dsp_v2")?.state == .new)
        #expect(knowledge.table(named: "v_dsp_report")?.state == .fresh)
        #expect(report.tables == .init(total: 3, new: 1, changed: 1, dropped: 1))
        #expect(report.possibleRenames == [["dsp", "dsp_v2"]], "same structure, never moved automatically")
        #expect(knowledge.serverVersion == "PostgreSQL 18.1")
    }

    @Test func lineageBecomesRelationshipsThatNeverJoin() {
        let (knowledge, _) = refreshed([schema()])
        let lineage = knowledge.relationships.filter { $0.kind == .lineage }
        #expect(Set(lineage.map(\.to.table)) == ["dsp", "report_adx_hour"])
        #expect(lineage.allSatisfy { $0.from.table == "v_dsp_report" && $0.evidence.map(\.source) == [.lineage] })
    }

    // Machine evidence is recomputed on every refresh; what the user and the AI added stays.
    @Test func machineEvidenceIsReplacedCuratedEvidenceKept() throws {
        let from = Relationship.End(table: "report_adx_hour", columns: ["dsp_id"])
        let to = Relationship.End(table: "dsp", columns: ["id"])
        let naming = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 55, at: now)])
        let gone = Relationship(from: .init(table: "report_adx_hour", columns: ["hour"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .naming, score: 30, at: now)])
        var (knowledge, _) = refreshed([schema()], machine: [[naming, gone]])
        let id = naming.id
        let index = try #require(knowledge.relationships.firstIndex { $0.id == id })
        knowledge.relationships[index].evidence.append(Evidence(source: .code, path: "dao.go", line: 12, by: "ai:claude-code", at: now))
        let rerun = Relationship(from: from, to: to, kind: .manyToOne, evidence: [Evidence(source: .naming, score: 60, at: later)])
        let report = KnowledgeRefresher.apply(schema(), machineRelationships: [rerun], to: &knowledge, now: later)
        let kept = try #require(knowledge.relationships.first { $0.id == id })
        #expect(kept.evidence.map(\.source).sorted { $0.rawValue < $1.rawValue } == [.code, .naming])
        #expect(kept.evidence.first { $0.source == .naming }?.score == 60)
        #expect(!knowledge.relationships.contains { $0.id == gone.id }, "machine-only evidence that is gone takes the relationship with it")
        #expect(report.relationships.removed == 1)
    }

    @Test func tombstonedRelationshipsAreNotInferredAgain() {
        let naming = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .naming, score: 55, at: now)])
        var knowledge = DatabaseKnowledge(key: key)
        knowledge.tombstones = [Tombstone(id: naming.id, deletedAt: now, by: "user")]
        _ = KnowledgeRefresher.apply(schema(), machineRelationships: [naming], to: &knowledge, now: now)
        #expect(!knowledge.relationships.contains { $0.id == naming.id })
    }

    @Test func notesAndRelationshipsGoStaleWhenTheirTableChanges() throws {
        var (knowledge, _) = refreshed([schema()])
        let report = try #require(knowledge.table(named: "report_adx_hour"))
        knowledge.notes.append(Note(id: "n1", table: "report_adx_hour", column: "dsp_id", kind: .caveat, text: "0 means house ads", evidence: [],
                                    by: "ai:codex", at: now, fingerprint: report.fingerprint))
        let curated = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                   evidence: [Evidence(source: .ai, by: "ai:codex", at: now)],
                                   fingerprints: ["report_adx_hour": report.fingerprint, "dsp": knowledge.table(named: "dsp")?.fingerprint ?? ""])
        knowledge.relationships.append(curated)
        #expect(!KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(!KnowledgeFreshness.isStale(curated, in: knowledge))

        let refresh = KnowledgeRefresher.apply(schema(dspIDType: "varchar(32)"), machineRelationships: [], to: &knowledge, now: later)
        #expect(KnowledgeFreshness.isStale(knowledge.notes[0], in: knowledge))
        #expect(KnowledgeFreshness.isStale(try #require(knowledge.relationships.first { $0.id == curated.id }), in: knowledge))
        #expect(refresh.notesStale == 1)
        #expect(refresh.relationships.nowStale == 1)
    }

    @Test func relationshipsToMissingColumnsAreBroken() {
        let (knowledge, _) = refreshed([schema()])
        let broken = Relationship(from: .init(table: "report_adx_hour", columns: ["app_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                  evidence: [Evidence(source: .ai, at: now)])
        #expect(KnowledgeFreshness.isBroken(broken, in: knowledge))
        let fine = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(table: "dsp", columns: ["id"]), kind: .manyToOne,
                                evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(fine, in: knowledge))
        let otherDatabase = Relationship(from: .init(table: "report_adx_hour", columns: ["dsp_id"]), to: .init(database: "admin", table: "dsp", columns: ["id"]),
                                         kind: .manyToOne, evidence: [Evidence(source: .ai, at: now)])
        #expect(!KnowledgeFreshness.isBroken(otherDatabase, in: knowledge), "another database's columns are checked against its own knowledge")
    }
}

@Suite("Knowledge extraction")
struct KnowledgeExtractionTests {
    private struct FakeSource: KnowledgeSchemaSource {
        let knowledgeServerVersion: String? = "PostgreSQL 18.1"
        func knowledgeSchema(_ schema: String, database: String?) async throws -> KnowledgeSchemaRows {
            KnowledgeSchemaRows(
                relations: [relation("orders", "p", partitionKey: "RANGE (created_at, (region))"), relation("customers"), relation("v_x", "v", definition: "SELECT id FROM orders"),
                            relation("mv_x", "m", definition: "SELECT id FROM orders"), relation("remote", "f")],
                columns: ["orders": [column("orders", "id", "bigint", nullable: false), column("orders", "customer_id", "bigint")],
                          "customers": [column("customers", "id", "bigint", nullable: false), column("customers", "tenant", "text", nullable: false),
                                        column("customers", "code", "text", nullable: false)]],
                constraints: [KnowledgeConstraintRow(table: "orders", kind: .primary, columns: ["id"]),
                              KnowledgeConstraintRow(table: "customers", kind: .primary, columns: ["id"]),
                              KnowledgeConstraintRow(table: "customers", kind: .unique, columns: ["tenant", "code"]),
                              KnowledgeConstraintRow(table: "orders", kind: .foreign, columns: ["customer_id"], referencedSchema: "sales", referencedTable: "customers",
                                                     referencedColumns: ["id"], isValidated: false),
                              KnowledgeConstraintRow(table: "orders", kind: .foreign, columns: ["region"], referencedSchema: "ref", referencedTable: "regions",
                                                     referencedColumns: ["code"])])
        }
        func knowledgeServerIdentifier(database: String?) async -> String? { "7312345678901234567" }
    }

    @Test func oneSchemaFromItsCatalog() async throws {
        let schema = try await KnowledgeExtractor.extract(schema: "sales", database: "shop", from: FakeSource())
        #expect(schema.tables.map(\.name) == ["orders", "customers", "v_x", "mv_x", "remote"])
        #expect(schema.tables.map(\.kind) == [.table, .table, .view, .materializedView, .externalTable])
        #expect(schema.tables.first { $0.name == "orders" }?.keys.partition == ["created_at", "(region)"])
        #expect(schema.tables.first { $0.name == "customers" }?.keys.unique == [["tenant", "code"]])
        #expect(schema.tables.first { $0.name == "v_x" }?.definition == "SELECT id FROM orders")
        #expect(schema.serverVersion == "PostgreSQL 18.1" && schema.serverIdentifier == "7312345678901234567")
        #expect(schema.foreignKeys.map(\.referencedTable) == ["customers", "regions"])
        #expect(schema.foreignKeys.map(\.isGuaranteed) == [false, true], "NOT VALID is not guaranteed")
    }

    @Test func postgresOwnSchemasAreRefused() async {
        for schema in ["pg_catalog", "information_schema", "pg_toast", "pg_temp_3"] {
            await #expect(throws: KnowledgeExtractor.Failure.self) { try await KnowledgeExtractor.extract(schema: schema, database: nil, from: FakeSource()) }
        }
    }
}
