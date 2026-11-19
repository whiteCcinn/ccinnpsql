import Foundation
import Testing
@testable import PostgresKit

@Suite("Knowledge SQL")
struct KnowledgeSQLTests {
    @Test func partitionsAreLeftOutWhereTheServerHasThem() {
        let modern = KnowledgeSQL.relations(ServerVersion(major: 18, minor: 0))
        #expect(modern.contains("NOT c.relispartition") && modern.contains("pg_get_partkeydef"))
        let old = KnowledgeSQL.relations(ServerVersion(major: 9, minor: 6))
        #expect(!old.contains("relispartition") && !old.contains("pg_get_partkeydef"), "9.6 has neither")
        #expect(!KnowledgeSQL.columns(ServerVersion(major: 9, minor: 6)).contains("relispartition"))
    }

    @Test func notEnforcedIsReadFromEighteenOn() {
        #expect(KnowledgeSQL.constraints(ServerVersion(major: 18, minor: 0)).contains("k.conenforced"))
        #expect(!KnowledgeSQL.constraints(ServerVersion(major: 17, minor: 0)).contains("conenforced"))
        #expect(KnowledgeSQL.constraints(ServerVersion(major: 17, minor: 0)).contains("true AS enforced"))
    }

    @Test func everyStatementTakesTheSchemaAsAParameter() {
        for sql in [KnowledgeSQL.relations(ServerVersion(major: 16, minor: 0)), KnowledgeSQL.columns(ServerVersion(major: 16, minor: 0)),
                    KnowledgeSQL.constraints(ServerVersion(major: 16, minor: 0)), KnowledgeSQL.visibleRelations] {
            #expect(sql.contains("n.nspname = $1"), "the schema is bound, never spliced")
        }
    }

    @Test func partitionKeyColumns() {
        #expect(KnowledgeSQL.partitionColumns("RANGE (created_at)") == ["created_at"])
        #expect(KnowledgeSQL.partitionColumns("LIST (region, \"Kind\")") == ["region", "Kind"])
        #expect(KnowledgeSQL.partitionColumns("RANGE (date_trunc('day'::text, ts), id)") == ["date_trunc('day'::text, ts)", "id"])
        #expect(KnowledgeSQL.partitionColumns(nil).isEmpty && KnowledgeSQL.partitionColumns("HASH").isEmpty && KnowledgeSQL.partitionColumns(") (").isEmpty)
    }
}
