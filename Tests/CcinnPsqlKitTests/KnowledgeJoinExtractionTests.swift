import Foundation
import Testing
@testable import CcinnPsqlKit

// JOIN mining reads equi-joins out of PostgreSQL statements: table references per SELECT block, then the conditions
// between them. `database` in a TableReference is the schema as written.

private func describe(_ pair: JoinPair) -> String {
    func side(_ reference: TableReference, _ columns: [String]) -> String {
        (reference.database.map { $0 + "." } ?? "") + reference.table + "(" + columns.joined(separator: ",") + ")"
    }
    return side(pair.left, pair.leftColumns) + "=" + side(pair.right, pair.rightColumns)
}

/// Joins of `sql` as `schema.table(columns)=table(columns)`; `columns` keys are `table` or `schema.table` as written.
private func joins(_ sql: String, columns: [String: [String]] = [:]) -> [String] {
    SQLJoinExtractor.joins(in: sql, columnsOf: { (reference: TableReference) -> [String]? in
        columns[(reference.database.map { $0 + "." } ?? "") + reference.table]
    }).map(describe)
}

private func scopes(_ sql: String) -> [SQLTableReferences.Scope] {
    let lexer = SQLLexer(sql)
    return SQLTableReferences.scopes(tokens: lexer.tokens().filter { $0.kind != .comment }, lexer: lexer)
}

private func names(_ scope: SQLTableReferences.Scope) -> [String] {
    scope.references.map { [$0.catalog, $0.database, $0.table].compactMap { $0 }.joined(separator: ".") + ($0.alias.map { " " + $0 } ?? "") }
}

/// A small deterministic generator for the fuzz test (SplitMix64).
private struct SplitMix {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

@Suite("Table references")
struct TableReferenceTests {
    @Test func eachSubqueryHasItsOwnScope() {
        let result = scopes("SELECT * FROM shop.orders o WHERE o.id IN (SELECT i.order_id FROM items i JOIN products p ON i.sku = p.sku)")
        #expect(result.count == 2)
        #expect(names(result[0]) == ["shop.orders o"])
        #expect(names(result[1]) == ["items i", "products p"])
        #expect(result[1].parent == 0)
    }

    @Test func derivedTablesAndCTEsCarryTheirColumns() {
        let result = scopes("""
        WITH top AS (SELECT city, SUM(total) AS revenue FROM orders GROUP BY city)
        SELECT * FROM top t JOIN (SELECT id AS customer_id FROM customers) c ON t.city = c.customer_id
        """)
        #expect(result[0].references.first { $0.alias == "t" }?.derivedColumns == ["city", "revenue"])
        #expect(result[0].references.first { $0.alias == "c" }?.derivedColumns == ["customer_id"])
        #expect(result.count == 3)
    }

    @Test func databaseSchemaAndTable() {
        let reference = scopes("select * from ads.shop.orders").first?.references.first
        #expect(reference?.catalog == "ads" && reference?.database == "shop" && reference?.table == "orders")
    }

    @Test func postgresFromItems() {
        #expect(names(scopes("SELECT * FROM ONLY shop.orders o")[0]) == ["shop.orders o"], "ONLY is not a table")
        #expect(names(scopes("SELECT * FROM orders * o")[0]) == ["orders o"], "the inheritance star is stepped over")
        #expect(names(scopes("SELECT * FROM orders o LEFT JOIN items i ON o.id = i.order_id")[0]) == ["orders o", "items i"],
                "LEFT is no alias")
        #expect(names(scopes("SELECT * FROM orders NATURAL JOIN items")[0]) == ["orders", "items"])
        #expect(names(scopes("SELECT * FROM orders CROSS JOIN items")[0]) == ["orders", "items"])
        #expect(names(scopes("SELECT * FROM orders o, LATERAL (SELECT * FROM items i WHERE i.order_id = o.id) x")[0]).first == "orders o")
        #expect(names(scopes("SELECT * FROM orders TABLESAMPLE SYSTEM (10)")[0]) == ["orders"])
    }

    @Test func unquotedNamesFoldQuotedNamesKeepTheirCase() {
        #expect(names(scopes(#"SELECT * FROM Shop.Orders O JOIN "Shop"."Items" "I" ON O.id = "I".order_id"#)[0])
            == ["shop.orders o", "Shop.Items I"])
    }

    @Test func deepNestingStopsInsteadOfOverflowing() {
        let sql = String(repeating: "SELECT * FROM (", count: 5_000) + "SELECT 1" + String(repeating: ") t", count: 5_000)
        let lexer = SQLLexer(sql)
        #expect(SQLTableReferences.scopes(tokens: lexer.tokens(), lexer: lexer).count == SQLTableReferences.maxScopeDepth + 1)
    }
}

@Suite("JOIN extraction")
struct JoinExtractionTests {
    @Test func onConditions() {
        #expect(joins("SELECT * FROM report r JOIN dsp d ON r.dsp_id = d.id") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report AS r LEFT OUTER JOIN dsp AS d ON d.id = r.dsp_id AND d.status = 1 WHERE r.dt = '2026-11-01'")
            == ["dsp(id)=report(dsp_id)"])
        #expect(joins("SELECT * FROM report JOIN dsp ON report.dsp_id = dsp.id") == ["report(dsp_id)=dsp(id)"], "unaliased tables")
        #expect(joins("SELECT * FROM a FULL JOIN b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x IS NOT DISTINCT FROM b.y").isEmpty, "only plain equality counts")
    }

    @Test func usingNeedsExactlyOnePriorTable() {
        #expect(joins("SELECT * FROM a JOIN b USING (k1, k2)") == ["a(k1,k2)=b(k1,k2)"])
        #expect(joins("SELECT * FROM a JOIN b USING (x) JOIN c USING (y)") == ["a(x)=b(x)"])
        #expect(joins("SELECT * FROM a, b JOIN c USING (k)").isEmpty)
        #expect(joins("SELECT * FROM a NATURAL JOIN b").isEmpty, "NATURAL names no columns")
    }

    @Test func implicitJoinsInWhere() {
        #expect(joins("SELECT * FROM report r, dsp d WHERE r.dsp_id = d.id AND r.dt = '2026-11-01'") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM report r WHERE r.dsp_id = r.app_id").isEmpty, "one table")
    }

    @Test func compositeConditionsBecomeOnePair() {
        #expect(joins("SELECT * FROM h JOIN d ON h.dt = d.dt AND d.app_id = h.app_id AND h.dt = d.dt") == ["h(dt,app_id)=d(dt,app_id)"])
        #expect(joins("SELECT * FROM a JOIN b ON (a.x = b.y AND ((a.z) = (b.w)))") == ["a(x,z)=b(y,w)"])
    }

    @Test func foldingAndQuotedNames() {
        #expect(joins(#"SELECT * FROM "adx"."report" AS "r" JOIN dsp AS d ON "r"."dsp_id" = d."id""#) == ["adx.report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM Report R JOIN Dsp D ON R.Dsp_Id = D.Id") == ["report(dsp_id)=dsp(id)"], "unquoted names fold")
        #expect(joins(#"SELECT * FROM "Report" r JOIN dsp d ON r."DspId" = d.id"#) == ["Report(DspId)=dsp(id)"], "quoted names keep case")
        #expect(joins("SELECT * FROM emp e JOIN emp m ON e.manager_id = m.id") == ["emp(manager_id)=emp(id)"], "self join")
    }

    @Test func schemaQualifiedNames() {
        #expect(joins("SELECT * FROM adx.report r JOIN admin.dsp d ON r.dsp_id = d.id") == ["adx.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM adx.report JOIN admin.dsp ON adx.report.dsp_id = admin.dsp.id") == ["adx.report(dsp_id)=admin.dsp(id)"])
        #expect(joins("SELECT * FROM ads.adx.report r JOIN adx.dsp d ON r.dsp_id = d.id") == ["adx.report(dsp_id)=adx.dsp(id)"],
                "database.schema.table")
        #expect(joins("SELECT * FROM ONLY adx.report r JOIN adx.dsp d ON r.dsp_id = d.id") == ["adx.report(dsp_id)=adx.dsp(id)"])
    }

    @Test func eachSubqueryResolvesItsOwnAliases() {
        let nested = "SELECT * FROM report r WHERE r.dsp_id IN (SELECT d.id FROM dsp d JOIN dsp_owner r ON d.owner_id = r.id)"
        #expect(joins(nested) == ["dsp(owner_id)=dsp_owner(id)"])
        #expect(joins("SELECT * FROM report r WHERE EXISTS (SELECT 1 FROM dsp d WHERE d.id = r.dsp_id)") == ["dsp(id)=report(dsp_id)"])
        #expect(joins("SELECT * FROM orders o, LATERAL (SELECT * FROM items i WHERE i.order_id = o.id) x") == ["items(order_id)=orders(id)"],
                "a LATERAL subquery sees the tables before it")
    }

    @Test func cteAndDerivedSidesAreSkipped() {
        #expect(joins("WITH t AS (SELECT dsp_id FROM report) SELECT * FROM t JOIN dsp d ON t.dsp_id = d.id").isEmpty)
        #expect(joins("WITH t AS (SELECT r.dsp_id FROM report r JOIN dsp d ON r.dsp_id = d.id) SELECT * FROM t") == ["report(dsp_id)=dsp(id)"])
        #expect(joins("WITH RECURSIVE t AS (SELECT 1 AS x) SELECT * FROM t JOIN b ON t.x = b.y").isEmpty)
    }

    @Test func onlyColumnEqualitiesCount() {
        #expect(joins("SELECT * FROM a JOIN b ON a.x = 5").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = $1").isEmpty, "a parameter")
        #expect(joins("SELECT * FROM a JOIN b ON a.x = E'5'").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.x = $q$5$q$").isEmpty, "a dollar-quoted string")
        #expect(joins("SELECT * FROM a JOIN b ON a.x::bigint = b.y").isEmpty, "a cast")
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y OR a.z = b.w").isEmpty)
        #expect(joins("SELECT * FROM a JOIN b ON a.arr[1] = b.y").isEmpty, "an array element")
        #expect(joins("SELECT * FROM a JOIN b ON a.dt BETWEEN b.start_dt AND b.end_dt AND a.id = b.a_id") == ["a(id)=b(a_id)"])
    }

    @Test func unqualifiedColumnsNeedExactlyOneOwner() {
        let known = ["report": ["dsp_id", "dt"], "dsp": ["id", "name"], "a": ["k"], "b": ["k", "k2"]]
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id", columns: known) == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM a JOIN b ON k = b.k2", columns: known).isEmpty, "two tables have k")
        #expect(joins("SELECT * FROM report r JOIN dsp d ON dsp_id = id").isEmpty, "nothing known")
    }

    @Test func commentsAndScripts() {
        #expect(joins("SELECT * FROM report r -- JOIN x ON r.a = x.b\nJOIN /* outer /* nested */ still */ dsp d ON r.dsp_id = d.id")
            == ["report(dsp_id)=dsp(id)"])
        #expect(joins("SELECT * FROM a JOIN b ON a.x = b.y; SELECT * FROM c, d WHERE c.k = d.k;") == ["a(x)=b(y)", "c(k)=d(k)"])
        #expect(joins("INSERT INTO t SELECT * FROM a JOIN b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("CREATE MATERIALIZED VIEW mv AS SELECT * FROM a JOIN b ON a.x = b.y") == ["a(x)=b(y)"])
        #expect(joins("DO $$ BEGIN PERFORM 1 FROM a JOIN b ON a.x = b.y; END $$").isEmpty, "a function body is a string")
    }

    @Test func deepNestingIsIgnoredNotWalked() {
        let deep = String(repeating: "(SELECT * FROM a JOIN b ON a.x = b.y WHERE a.k IN ", count: 3_000) + String(repeating: ")", count: 3_000)
        #expect(joins("SELECT 1 FROM t WHERE t.k IN " + deep).isEmpty)
    }

    @Test func hostileInputNeverCrashes() async {
        let found = await onDedicatedThread { () -> Int in
            var generator = SplitMix(state: 0x5EED)
            let vocabulary = [
                "SELECT", "FROM", "JOIN", "LEFT", "ON", "USING", "WHERE", "AND", "OR", "BETWEEN", "WITH", "AS", "IN", "EXISTS", "ONLY",
                "LATERAL", "NATURAL", "(", ")", "(", ")", ",", ";", ".", "=", "::", "a", "b", "t", "x.y", "a.x", "b.y", "\"Q\"", "s.t", "5",
                "'s'", "E'\\''", "$1", "$$", "$q$", "--c\n", "/*", "*/", "[", "]", "*", "+", "\"", "RECURSIVE",
                "SELECT * FROM a JOIN b ON a.x = b.y", "FROM a, b WHERE a.x = b.y", "USING (", "WITH c AS (",
            ]
            var total = 0
            for _ in 0..<600 {
                let length = Int(generator.next() % 80)
                var parts: [String] = []
                for _ in 0..<length { parts.append(vocabulary[Int(generator.next() % UInt64(vocabulary.count))]) }
                total += SQLJoinExtractor.joins(in: parts.joined(separator: " "), columnsOf: { (_: TableReference) -> [String]? in ["x", "y"] }).count
            }
            return total
        }
        #expect(found > 0)
    }
}

@Suite("SQL digests")
struct SQLDigestTests {
    @Test func literalsOfEveryPostgresKindBecomePlaceholders() {
        let sql = "SELECT * FROM t WHERE a = 'x' AND b = 5 AND c = $q$secret$q$ AND d = E'\\n' -- note\n AND e = $1"
        let digest = SQLDigest.digest(sql)
        #expect(digest.hasPrefix("SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ?") && digest.hasSuffix("AND e = $1"))
        #expect(!digest.contains("secret") && !digest.contains("note") && !digest.contains("'"))
    }
}
