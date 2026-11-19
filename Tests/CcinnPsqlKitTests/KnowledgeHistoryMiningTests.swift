import Foundation
import Testing
@testable import CcinnPsqlKit

// Relationships from editor history and from view definitions. Statement-level JOIN extraction is in
// KnowledgeJoinExtractionTests.swift.

// MARK: - History and definitions

@Suite("Knowledge inference: history mining")
struct KnowledgeInferenceHistoryTests {
    typealias F = KnowledgeInferenceFixtures

    private let key = DatabaseKey(cluster: ClusterKey(rawValue: "pg://fe.prod:9030"), catalog: "ads", database: "adx")
    private let admin = ["admin": [F.table("publisher", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("name", "varchar(64)")])]]

    private func knowledge() -> DatabaseKnowledge {
        var knowledge = DatabaseKnowledge(key: key)
        knowledge.tables = [
            F.table("app", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("name", "varchar(64)")]),
            F.table("dsp", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("publisher_id"), F.column("name", "varchar(64)")]),
            F.table("report_adx_day", primary: ["dt", "app_id"], [F.column("dt", "date", key: true), F.column("app_id", key: true), F.column("revenue", "numeric(18,6)")]),
            F.table("report_adx_hour", primary: ["dt", "hour", "dsp_id", "app_id"], [
                F.column("dt", "date", key: true), F.column("hour", "tinyint", key: true), F.column("dsp_id", key: true),
                F.column("app_id", key: true), F.column("dsp_request"),
            ]),
            F.table("old_report", state: .dropped, [F.column("dsp_id")]),
        ]
        return knowledge
    }

    private func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_790_000_000 + offset) }

    private func entry(_ sql: String, _ database: String?, _ offset: TimeInterval, error: String? = nil) -> QueryHistoryEntry {
        QueryHistoryEntry(sql: sql, database: database, executedAt: at(offset), durationMilliseconds: 5, errorMessage: error)
    }

    /// Profile A: default database `adx`.
    private var profileA: [QueryHistoryEntry] {
        [
            entry("SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-01'", "adx", 100),
            entry("SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = '2026-11-02'", "adx", 200),
            entry("SELECT * FROM report_adx_hour r JOIN app a ON r.app_id = a.id", "adx", 300, error: "Unknown column 'app_id'"),
            entry("SELECT * FROM dsp d JOIN admin.publisher p ON d.publisher_id = p.id; SHOW TABLES", "adx", 400),
            entry("UPDATE dsp SET name = 'x' WHERE id IN (SELECT r.dsp_id FROM report_adx_hour r JOIN app a ON r.app_id = a.id)", "adx", 500),
            entry("EXPLAIN SELECT * FROM report_adx_hour r JOIN app a ON r.app_id = a.id", "adx", 510),
            entry("SELECT * FROM report_adx_hour r JOIN old_report o ON r.dsp_id = o.dsp_id", "adx", 520),
        ]
    }

    /// Profile B: schema-qualified names; a schema the knowledge does not know resolves to nothing.
    private var profileB: [QueryHistoryEntry] {
        [
            entry("select * from adx.report_adx_hour r join adx.dsp d on d.id = r.dsp_id and r.dt = '2026-11-03' -- secret 42", nil, 600),
            entry("SELECT * FROM other.report_adx_hour r JOIN other.dsp d ON r.dsp_id = d.id", nil, 700),
            entry("SELECT * FROM adx.report_adx_hour h JOIN adx.report_adx_day x ON h.dt = x.dt AND h.app_id = x.app_id", "admin", 800),
            entry("INSERT INTO adx.report_adx_day SELECT x.dt, x.app_id, 1 FROM adx.report_adx_day x JOIN adx.app a ON x.app_id = a.id", "admin", 900),
            entry("SELECT * FROM adx.report_adx_day a JOIN adx.report_adx_hour b ON a.app_id = b.app_id", "admin", 1_000),
            entry("CREATE VIEW v AS SELECT d.id FROM adx.dsp d JOIN unknown_table u ON d.id = u.dsp_id", "admin", 1_100),
        ]
    }

    @Test func historyOfTwoProfilesBecomesRelationships() throws {
        let relationships = HistoryJoinMiner.relationships(entries: profileA + profileB, knowledge: knowledge(), otherDatabases: admin, now: F.now)
        #expect(relationships.map(F.describe).sorted() == [
            "dsp(publisher_id)->admin.publisher(id)",
            "report_adx_day(app_id)->app(id)",
            "report_adx_day(app_id)->report_adx_hour(app_id)",
            "report_adx_hour(app_id,dt)->report_adx_day(app_id,dt)",
            "report_adx_hour(dsp_id)->dsp(id)",
        ])
        #expect(relationships.map(\.id) == relationships.map(\.id).sorted())
        let kinds = Dictionary(uniqueKeysWithValues: relationships.map { (F.describe($0), $0.kind) })
        #expect(kinds["report_adx_day(app_id)->report_adx_hour(app_id)"] == .manyToMany, "no side is unique")
        #expect(kinds["report_adx_hour(app_id,dt)->report_adx_day(app_id,dt)"] == .manyToOne, "hours roll up into days")

        let dsp = try #require(relationships.first { F.describe($0) == "report_adx_hour(dsp_id)->dsp(id)" })
        #expect(dsp.kind == .manyToOne)
        #expect(dsp.fingerprints == ["report_adx_hour": "fp-report_adx_hour", "dsp": "fp-dsp"])
        #expect(dsp.evidence == [Evidence(source: .history, statements: 2, count: 3, lastSeen: at(600), samples: [
            "select * from adx.report_adx_hour r join adx.dsp d on d.id = r.dsp_id and r.dt = ?",
            "SELECT r.dt, d.name FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.dt = ?",
        ], at: F.now)])

        let publisher = try #require(relationships.first { $0.to.database == "admin" })
        #expect(publisher.fingerprints == ["dsp": "fp-dsp", "admin.publisher": "fp-publisher"])
    }

    @Test func samplesAreFewDigestsWithoutLiterals() throws {
        let shapes = (0..<5).map { (index: Int) -> QueryHistoryEntry in
            entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id WHERE r.hour = \(index) AND r.dt = 'secret-\(index)'"
                    + String(repeating: " AND r.dsp_request > 0", count: index), "adx", TimeInterval(index))
        }
        let relationship = try #require(HistoryJoinMiner.relationships(entries: shapes, knowledge: knowledge(), now: F.now).first)
        let evidence = try #require(relationship.evidence.first)
        #expect(evidence.statements == 5)
        #expect(evidence.count == 5)
        let samples = try #require(evidence.samples)
        #expect(samples.count == 3)
        #expect(samples.first?.hasSuffix(String(repeating: " AND r.dsp_request > ?", count: 4)) == true, "newest first")
        #expect(samples.allSatisfy { !$0.contains("secret") && !$0.contains("'") && $0.count <= 500 })
    }

    @Test func nothingFromFailedOrForeignStatements() {
        let failed = [entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.dsp_id = d.id", "adx", 1, error: "timeout")]
        #expect(HistoryJoinMiner.relationships(entries: failed, knowledge: knowledge(), now: F.now).isEmpty)
        let elsewhere = [entry("SELECT * FROM shop.orders o JOIN shop.users u ON o.user_id = u.id", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: elsewhere, knowledge: knowledge(), now: F.now).isEmpty)
        let missingColumn = [entry("SELECT * FROM report_adx_hour r JOIN dsp d ON r.nope = d.id", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: missingColumn, knowledge: knowledge(), now: F.now).isEmpty)
    }

    @Test func declaredKeysDecideTheDirection() {
        var withDeclared = knowledge()
        withDeclared.tables.append(F.table("dsp_owner", [F.column("code", "varchar(16)"), F.column("owner", "varchar(64)")]))
        withDeclared.tables.append(F.table("dsp_detail", [F.column("owner_code", "varchar(16)")]))
        let entries = [entry("SELECT * FROM dsp_owner o JOIN dsp_detail d ON o.code = d.owner_code", "adx", 1)]
        #expect(HistoryJoinMiner.relationships(entries: entries, knowledge: withDeclared, now: F.now).map(\.kind) == [.manyToMany])
        withDeclared.relationships = [Relationship(from: .init(table: "dsp_detail", columns: ["owner_code"]), to: .init(table: "dsp_owner", columns: ["code"]),
                                                   kind: .manyToOne, evidence: [Evidence(source: .declared)])]
        let mined = HistoryJoinMiner.relationships(entries: entries, knowledge: withDeclared, now: F.now)
        #expect(mined.map(F.describe) == ["dsp_detail(owner_code)->dsp_owner(code)"])
        #expect(mined.map(\.kind) == [.manyToOne])
    }

    // One table on both ends: one fingerprint (a dictionary literal with the key twice would trap).
    @Test func selfJoinsAreRelationshipsOfOneTable() throws {
        var staff = knowledge()
        staff.tables.append(F.table("emp", model: "PK", primary: ["id"], [F.column("id", key: true), F.column("manager_id")]))
        let entries = [
            entry("SELECT * FROM emp e JOIN emp m ON e.manager_id = m.id", "adx", 1),
            entry("SELECT * FROM emp a JOIN emp b ON a.id = b.id", "adx", 2),
        ]
        let mined = HistoryJoinMiner.relationships(entries: entries, knowledge: staff, now: F.now)
        #expect(mined.map(F.describe) == ["emp(manager_id)->emp(id)"], "joining a key to itself says nothing")
        #expect(try #require(mined.first).fingerprints == ["emp": "fp-emp"])
    }

    @Test func viewDefinitionsGiveDefinitionEvidence() throws {
        let view = HistoryJoinMiner.definitionRelationships(
            definition: #"SELECT r.dt, d.name FROM ("adx"."report_adx_hour" "r" JOIN "dsp" "d" ON (("r"."dsp_id" = "d"."id"))) WHERE (r.dt > '2026-01-01'::date)"#,
            viewName: "v_report", knowledge: knowledge(), now: F.now)
        #expect(view.map(F.describe) == ["report_adx_hour(dsp_id)->dsp(id)"])
        #expect(try #require(view.first).evidence == [Evidence(source: .definition, symbol: "v_report", at: F.now)])

        let materialized = HistoryJoinMiner.definitionRelationships(
            definition: "CREATE MATERIALIZED VIEW mv_day AS SELECT h.dt, sum(h.dsp_request) FROM report_adx_hour h JOIN app a ON h.app_id = a.id GROUP BY h.dt;",
            viewName: "mv_day", knowledge: knowledge(), now: F.now)
        #expect(materialized.map(F.describe) == ["report_adx_hour(app_id)->app(id)"])

        let crossDatabase = "SELECT * FROM dsp d JOIN admin.publisher p ON d.publisher_id = p.id"
        #expect(HistoryJoinMiner.definitionRelationships(definition: crossDatabase, viewName: "v", knowledge: knowledge(), now: F.now).isEmpty)
        #expect(HistoryJoinMiner.definitionRelationships(definition: crossDatabase, viewName: "v", knowledge: knowledge(), otherDatabases: admin, now: F.now)
            .map(F.describe) == ["dsp(publisher_id)->admin.publisher(id)"])
    }
}
