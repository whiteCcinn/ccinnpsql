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

    @Test func perPartitionCopiesOfAForeignKeyAreLeftOut() {
        #expect(KnowledgeSQL.constraints(ServerVersion(major: 12, minor: 0)).contains("k.conparentid = 0"))
        #expect(!KnowledgeSQL.constraints(ServerVersion(major: 10, minor: 0)).contains("conparentid"), "conparentid exists from 11")
    }

    @Test func extractionRunsReadOnlyWithOnlyThePostgresCatalogOnThePath() {
        #expect(KnowledgeSQL.catalogTransaction.contains("BEGIN TRANSACTION READ ONLY"))
        #expect(KnowledgeSQL.catalogTransaction.contains("SET LOCAL search_path = pg_catalog"),
                "names print schema-qualified for every profile, and unqualified functions resolve only in pg_catalog")
    }

    @Test func everyStatementTakesTheSchemaAsAParameter() {
        for sql in [KnowledgeSQL.relations(ServerVersion(major: 16, minor: 0)), KnowledgeSQL.columns(ServerVersion(major: 16, minor: 0)),
                    KnowledgeSQL.constraints(ServerVersion(major: 16, minor: 0)), KnowledgeSQL.readableColumns] {
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
