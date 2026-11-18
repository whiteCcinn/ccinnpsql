import Foundation
import Testing
@testable import CcinnPsqlKit
import PostgresKit
import PostgresWire

@Suite("Profiles and secrets")
struct ProfileTests {
    @Test func secretsNeverReachDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-profiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let secrets = InMemorySecretStore()
        let repository = ProfileRepository(directory: directory, secrets: secrets)
        var profile = ConnectionProfile(name: "Prod", host: "db.example", username: "app", database: "shop", sslMode: .verifyFull,
                                        rootCertificatePath: "/tmp/ca.pem", poolingMode: .transaction)
        profile.ssh = SSHTunnelConfiguration(host: "bastion", username: "ops", authentication: .password)
        try repository.save([profile])
        try repository.storeSecrets(for: profile, password: "hunter2-db", sshSecret: "hunter2-ssh")
        let json = try String(contentsOf: directory.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!json.contains("hunter2"))
        let loaded = try repository.load()
        #expect(loaded.first?.sslMode == .verifyFull)
        #expect(loaded.first?.poolingMode == .transaction)
        #expect(repository.password(for: profile) == "hunter2-db")
        #expect(repository.sshSecret(for: profile) == "hunter2-ssh")
        try repository.delete(profile)
        #expect(repository.password(for: profile) == nil)
    }

    @Test func configurationAndValidation() {
        let profile = ConnectionProfile(host: " db ", port: 6432, username: "app", database: "", sslMode: .require, sslNegotiation: .direct)
        let configuration = profile.configuration(password: "x")
        #expect(configuration.endpoint == Endpoint(host: "db", port: 6432))
        #expect(configuration.database == "postgres")
        #expect(configuration.tlsServerName == "db")
        #expect(profile.validationErrors.isEmpty)
        var invalid = ConnectionProfile(host: "", port: 0, username: "", sslMode: .prefer, sslNegotiation: .direct)
        invalid.ssh = SSHTunnelConfiguration(host: "", username: "u", authentication: .privateKey)
        #expect(invalid.validationErrors.count == 6)
    }
}

@Suite("Completion")
struct CompletionTests {
    let snapshot = SchemaSnapshot(
        searchPath: ["public"], schemas: ["public", "shop"],
        objectsBySchema: ["public": [.init(name: "users", kind: .table)],
                          "shop": [.init(name: "orders", kind: .table), .init(name: "daily_revenue", kind: .materializedView),
                                   .init(name: "Mixed Case", kind: .view), .init(name: "invoice_numbers", kind: .sequence)]],
        columnsByTable: [TableKey(schema: "shop", table: "orders"): [.init(name: "id", type: "bigint"), .init(name: "customer_id", type: "bigint")],
                         TableKey(schema: "public", table: "users"): [.init(name: "email", type: "text")]],
        functionsBySchema: ["public": [RoutineSummary(oid: 1, schema: "public", name: "order_total", kind: .function, arguments: "bigint",
                                                      result: "numeric", language: "sql", volatility: "s")]])

    func labels(_ text: String, cursor: Int? = nil) -> [String] {
        CompletionEngine.complete(text: text, cursor: cursor ?? text.utf16.count, schema: snapshot).items.map(\.label)
    }

    @Test func tablesSchemasAndQuoting() {
        #expect(labels("SELECT * FROM ").contains("users"))
        #expect(labels("SELECT * FROM ").contains("shop"))
        #expect(labels("SELECT * FROM shop.").contains("orders"))
        #expect(!labels("SELECT * FROM shop.").contains("invoice_numbers"))
        let mixed = CompletionEngine.complete(text: "SELECT * FROM shop.Mix", cursor: 22, schema: snapshot).items.first
        #expect(mixed?.insertText == "\"Mixed Case\"")
        #expect(labels("REFRESH MATERIALIZED VIEW shop.") == ["daily_revenue"])
    }

    @Test func columnsThroughAliasesAndSearchPath() {
        #expect(labels("SELECT o. FROM shop.orders o", cursor: 9).contains("customer_id"))
        #expect(labels("SELECT  FROM users", cursor: 7).contains("email"))
        #expect(labels("SELECT users. FROM users", cursor: 13) == ["email"])
        #expect(labels("SELECT ord").contains("order_total"))
        #expect(labels("SELECT x::").contains("jsonb"))
        #expect(labels("SET search_path TO ").contains("shop"))
    }

    @Test func missingSchemaIsReportedNotRequeried() {
        let partial = SchemaSnapshot(searchPath: ["public"], schemas: ["public", "other"])
        let result = CompletionEngine.complete(text: "SELECT * FROM other.", cursor: 20, schema: partial)
        #expect(result.missingSchemas == ["other"])
        let columns = CompletionEngine.complete(text: "SELECT  FROM other.t", cursor: 7, schema: partial)
        #expect(columns.missingColumns == [TableKey(schema: "other", table: "t")])
    }

    private func result(_ textWithCursor: String) -> CompletionResult {
        let cursor = (textWithCursor as NSString).range(of: "|").location
        return CompletionEngine.complete(text: textWithCursor.replacingOccurrences(of: "|", with: ""), cursor: cursor, schema: snapshot)
    }

    // The editor opens the list on whitespace only where a relation or schema name must follow.
    @Test func objectNameContextsAreFlagged() {
        for text in ["SELECT * FROM |", "SELECT * FROM shop.orders o JOIN |", "SELECT * FROM users u, |", "INSERT INTO |", "UPDATE |",
                     "TRUNCATE |", "TRUNCATE TABLE |", "SELECT * FROM ONLY |", "REFRESH MATERIALIZED VIEW |", "SET search_path TO |",
                     "SELECT 1;\nSELECT * FROM |"] {
            #expect(result(text).expectsObjectName, "\(text)")
        }
        for text in ["|", "SELECT |", "SELECT * FROM users u |", "SELECT * FROM users WHERE email = |", "SELECT * FROM shop.|",
                     "SELECT * FROM users ORDER BY email DESC |", "SELECT * FROM users FETCH FIRST 10 ROWS ONLY |",
                     "SELECT 'FROM |'", "SELECT 1 -- FROM |", "SELECT 1::|"] {
            #expect(!result(text).expectsObjectName, "\(text)")
        }
    }

    // `FETCH FIRST n ROWS ONLY` ends a query; only `ONLY` right after FROM/JOIN/UPDATE/TABLE/TRUNCATE names a table.
    @Test func onlyAfterFetchIsNotATablePosition() {
        #expect(!labels("SELECT * FROM users FETCH FIRST 10 ROWS ONLY ").contains("users"))
        #expect(labels("SELECT * FROM ONLY ").contains("users"))
        #expect(labels("ALTER TABLE ONLY us").first == "users")
    }

    @Test func noCompletionInsideStringsAndComments() {
        #expect(labels("SELECT 'us").isEmpty)
        #expect(labels("SELECT 1 -- us").isEmpty)
        #expect(labels("SELECT $$ us").isEmpty)
    }
}

@Suite("Export")
struct ExportTests {
    let columns = [ColumnDescription(name: "id", typeOID: 20), ColumnDescription(name: "name", typeOID: 25),
                   ColumnDescription(name: "ok", typeOID: 16), ColumnDescription(name: "doc", typeOID: 3802)]
    let rows: [[String?]] = [["1", "=cmd()", "t", "{\"a\": 1}"], ["-2", "a,\"b\"", nil, nil]]

    @Test func csvNeutralizesFormulasButKeepsNumbers() {
        let csv = ResultExport.csv(columns: columns, rows: rows)
        #expect(csv == "id,name,ok,doc\r\n1,'=cmd(),t,\"{\"\"a\"\": 1}\"\r\n-2,\"a,\"\"b\"\"\",,\r\n")
    }

    @Test func jsonKeepsTypes() throws {
        let json = ResultExport.render(.json, columns: columns, rows: rows)
        let parsed = try JSONValue.parse(json)
        #expect(parsed[0]?["id"] == .int(1))
        #expect(parsed[0]?["ok"] == .bool(true))
        #expect(parsed[0]?["doc"]?["a"] == .int(1))
        #expect(parsed[1]?["name"] == .string("a,\"b\""))
        #expect(parsed[1]?["ok"] == .null)
    }

    @Test func markdownInsertAndCopy() {
        let markdown = ResultExport.render(.markdown, columns: columns, rows: [["1", "a|b", "f", nil]])
        #expect(markdown.contains("| id | name | ok | doc |\n| ---: | --- | --- | --- |\n| 1 | a\\|b | f | NULL |"))
        let insert = ResultExport.insertStatements(table: "shop.t", columns: columns, rows: [["1", "it's", "f", nil]])
        #expect(insert == "INSERT INTO shop.t (id, name, ok, doc) VALUES (1, 'it''s', false, NULL);\n")
        #expect(ResultExport.copyStatement(for: "SELECT * FROM t;") == "COPY (SELECT * FROM t\n) TO STDOUT WITH (FORMAT csv, HEADER)")
        // Review finding 7: a trailing line comment must not comment out the closing parenthesis.
        let commented = ResultExport.copyStatement(for: "SELECT * FROM t -- newest first ;")
        #expect(commented == "COPY (SELECT * FROM t -- newest first\n) TO STDOUT WITH (FORMAT csv, HEADER)")
        #expect(ResultExport.tsv(columns: columns, rows: [["1", "a\tb", nil, nil]]) == "id\tname\tok\tdoc\n1\ta b\t\t")
    }
}

@Suite("Charts")
struct ChartTests {
    @Test func suggestsTimeSeriesAndSkipsNonFinite() {
        let columns = [ColumnDescription(name: "day", typeOID: 1184), ColumnDescription(name: "revenue", typeOID: 701)]
        let rows: [[String?]] = [["2024-01-01 00:00:00+00", "10"], ["2024-01-02 00:00:00+00", "NaN"], ["2024-01-03 00:00:00+00", "Infinity"],
                                 ["2024-01-04 00:00:00+00", "12.5"]]
        let spec = ChartSuggester.suggest(columns: columns, rows: rows)
        #expect(spec?.kind == .line)
        let roles = ChartSuggester.roles(columns: columns, rows: rows)
        let data = ChartDataBuilder.build(columns: columns, rows: rows, spec: spec!, roles: roles)
        #expect(data.points.count == 2)
        #expect(data.skippedRows == 2)
    }

    @Test func numericTextAndBooleanRoles() {
        let columns = [ColumnDescription(name: "n", typeOID: 25), ColumnDescription(name: "flag", typeOID: 16), ColumnDescription(name: "x", typeOID: 1700)]
        let roles = ChartSuggester.roles(columns: columns, rows: [["1", "t", "1.5"], ["2", "f", "2"]])
        #expect(roles == [.numeric, .categorical, .numeric])
    }
}

@Suite("EXPLAIN plans")
struct ExplainTests {
    static let analyzed = """
    [{"Plan": {"Node Type": "Hash Join", "Join Type": "Inner", "Startup Cost": 1.0, "Total Cost": 50.0, "Plan Rows": 10, "Plan Width": 16,
      "Actual Startup Time": 0.5, "Actual Total Time": 12.0, "Actual Rows": 1000, "Actual Loops": 1, "Hash Cond": "(o.customer_id = c.id)",
      "Plans": [
        {"Node Type": "Seq Scan", "Parent Relationship": "Outer", "Relation Name": "orders", "Schema": "shop", "Alias": "o",
         "Total Cost": 30.0, "Plan Rows": 2000, "Actual Total Time": 8.0, "Actual Rows": 2000, "Actual Loops": 1,
         "Filter": "(status = 'paid'::order_status)", "Rows Removed by Filter": 6000, "Shared Hit Blocks": 20, "Shared Read Blocks": 5},
        {"Node Type": "Hash", "Parent Relationship": "Inner", "Total Cost": 5.0, "Plan Rows": 200, "Actual Total Time": 1.0, "Actual Rows": 200,
         "Actual Loops": 1, "Plans": [
           {"Node Type": "Index Scan", "Parent Relationship": "Outer", "Index Name": "customers_pkey", "Relation Name": "customers",
            "Alias": "c", "Total Cost": 4.0, "Plan Rows": 200, "Actual Total Time": 0.25, "Actual Rows": 50, "Actual Loops": 4}]}
      ]},
      "Planning Time": 0.3, "Execution Time": 12.5, "Triggers": [{"Trigger Name": "t1", "Time": 1.5, "Calls": 3}]}]
    """

    @Test func parsesAndDerivesMetrics() throws {
        let plan = try ExplainPlan.parse(Self.analyzed)
        #expect(plan.isAnalyzed)
        #expect(plan.nodes.count == 4)
        #expect(plan.executionTime == 12.5)
        #expect(plan.root.title == "Inner Hash Join")
        #expect(plan.root.exclusiveTime == 3.0) // 12 − 8 − 1
        let scan = plan.nodes[1]
        #expect(scan.relation == "shop.orders")
        #expect(scan.subtitle == "on shop.orders o")
        #expect(scan.details.first?.name == "Filter")
        #expect(plan.slowestNode?.id == scan.id)
        #expect(plan.root.isMisestimated) // 10 planned vs 1000 actual
        #expect(plan.root.underestimated)
        let index = plan.nodes[3]
        #expect(index.subtitle == "using customers_pkey on customers c")
        #expect(index.totalActualRows == 200)
        #expect(plan.triggers.first?.name == "t1")
        #expect(plan.summary().contains("[rows underestimated 100×]"))
    }

    @Test func plainPlansAndBadInput() throws {
        let plain = try ExplainPlan.parse(#"[{"Plan": {"Node Type": "Result", "Total Cost": 0.01, "Plan Rows": 1}}]"#)
        #expect(!plain.isAnalyzed)
        #expect(plain.slowestNode == nil)
        #expect(plain.root.exclusiveTime == nil)
        #expect(throws: ExplainPlan.ParseError.self) { try ExplainPlan.parse("QUERY PLAN\nSeq Scan") }
        #expect(throws: ExplainPlan.ParseError.self) { try ExplainPlan.parse(#"[{"NoPlan": 1}]"#) }
        #expect(ExplainPlan.statement(for: "SELECT 1;", analyze: true, buffers: true) == "EXPLAIN (FORMAT JSON, ANALYZE, BUFFERS) SELECT 1")
        // The prefix maps server error positions back to the statement in the editor.
        #expect(ExplainPlan.statementPrefix(analyze: false, buffers: false) == "EXPLAIN (FORMAT JSON) ")
        #expect(ExplainPlan.statement(for: "SELECT 1", analyze: false, buffers: false) == ExplainPlan.statementPrefix(analyze: false, buffers: false) + "SELECT 1")
    }

    @Test func fuzzedPlansNeverTrap() {
        var generator = SystemRandomNumberGenerator()
        let fragments = ["{", "}", "[", "]", "\"Plan\"", ":", ",", "\"Node Type\"", "\"Plans\"", "1e309", "-1", "null", "\"x\"", "true"]
        for _ in 0..<2_000 {
            let text = (0..<Int.random(in: 0..<40, using: &generator)).map { _ in fragments.randomElement(using: &generator)! }.joined()
            _ = try? ExplainPlan.parse(text)
        }
    }
}

@Suite("History")
struct HistoryTests {
    @Test func redactsAndKeepsFilesPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccinnpsql-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = QueryHistoryStore(directory: directory, profileID: UUID(), maxEntries: 3)
        await store.append(QueryHistoryEntry(sql: "ALTER ROLE app PASSWORD 'secret'", database: "shop", durationMilliseconds: 1))
        for index in 0..<5 { await store.append(QueryHistoryEntry(sql: "SELECT \(index)", database: "shop", durationMilliseconds: 1)) }
        let entries = await store.all()
        #expect(entries.count == 3)
        #expect(entries.first?.sql == "SELECT 4")
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!text.contains("secret"))
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }
}
