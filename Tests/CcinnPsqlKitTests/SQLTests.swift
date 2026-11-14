import Foundation
import Testing
@testable import CcinnPsqlKit

@Suite("PostgreSQL lexer")
struct LexerTests {
    func kinds(_ sql: String) -> [(SQLToken.Kind, String)] {
        let lexer = SQLLexer(sql)
        return lexer.tokens().map { ($0.kind, lexer.text(of: $0)) }
    }

    @Test func stringsAndQuotes() {
        let tokens = kinds("SELECT 'it''s', E'a\\'b', U&'d\\0061t', $$x;y$$, $fn$ SELECT 1; $fn$, \"Mixed \"\"Case\", B'0101', X'1F'")
        let strings = tokens.filter { $0.0 == .string }.map(\.1)
        #expect(strings == ["'it''s'", "E'a\\'b'", "U&'d\\0061t'", "$$x;y$$", "$fn$ SELECT 1; $fn$", "B'0101'", "X'1F'"])
        #expect(tokens.contains { $0.0 == .quotedIdentifier && $0.1 == "\"Mixed \"\"Case\"" })
    }

    @Test func commentsNestAndParametersAreSeparate() {
        let tokens = kinds("/* a /* nested */ still */ SELECT $1::int -- tail")
        #expect(tokens.first?.0 == .comment)
        #expect(tokens.first?.1 == "/* a /* nested */ still */")
        #expect(tokens.contains { $0.0 == .parameter && $0.1 == "$1" })
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "::" })
        #expect(tokens.last?.0 == .comment)
    }

    @Test func numbersOperatorsAndIdentifiers() {
        let tokens = kinds("SELECT 1.5e3, .5, 1_000, 0x1F, a.b, c->>'k', d @> e, f::text[], g!=h, i#-j")
        #expect(tokens.filter { $0.0 == .number }.map(\.1) == ["1.5e3", ".5", "1_000", "0x1F"])
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "->>" })
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "@>" })
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "!=" })
        #expect(tokens.contains { $0.0 == .punctuation && $0.1 == "[" })
    }

    @Test func identifierValuesFoldCase() {
        let lexer = SQLLexer("Users \"Users\" U&\"x\"")
        let tokens = lexer.tokens()
        #expect(lexer.identifierValue(of: tokens[0]) == "users")
        #expect(lexer.identifierValue(of: tokens[1]) == "Users")
        #expect(lexer.identifierValue(of: tokens[2]) == "x")
    }

    @Test func unterminatedInputNeverTraps() {
        for sql in ["'abc", "$$abc", "$tag$ abc $ta", "/* /* */", "\"abc", "E'\\", "U&", "$", "$1a", "0x", "1e", "..", "::"] {
            _ = SQLLexer.tokenize(sql)
            _ = SQLStatementSplitter.split(sql)
            _ = SQLStatementKind.of(sql)
            _ = ReadOnlySQLGuard.check(sql)
            _ = SQLRedactor.redact(sql)
        }
    }

    @Test func fuzzedInputNeverTraps() {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("SELECTINSERTWITH'\"$;()/*-\\e&U0123456789 \n.,:@#".unicodeScalars) + ["é", "𝔸"]
        for _ in 0..<3_000 {
            var text = ""
            for _ in 0..<Int.random(in: 0..<60, using: &generator) { text.unicodeScalars.append(alphabet.randomElement(using: &generator)!) }
            _ = SQLLexer.tokenize(text)
            _ = SQLStatementSplitter.split(text)
            _ = SQLStatementKind.of(text)
            _ = ReadOnlySQLGuard.check(text)
            _ = SQLRedactor.redact(text)
            _ = AutoLimit.apply(to: text, limit: 10)
            _ = SQLErrorLocator.highlightRange(in: text, position: Int.random(in: -2..<80, using: &generator))
        }
    }
}

@Suite("Splitter")
struct SplitterTests {
    @Test func splitsOutsideStringsCommentsAndBodies() {
        let script = """
        SELECT 1; -- one;
        CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$;
        SELECT ';' AS "a;b"; /* ; */
        CREATE PROCEDURE p() BEGIN ATOMIC SELECT 1; SELECT 2; END;
        SELECT 2
        """
        let statements = SQLStatementSplitter.split(script)
        #expect(statements.map(\.text) == [
            "SELECT 1",
            "CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $$ BEGIN RETURN 1; END $$",
            "SELECT ';' AS \"a;b\"",
            "CREATE PROCEDURE p() BEGIN ATOMIC SELECT 1; SELECT 2; END",
            "SELECT 2",
        ])
        let units = Array(script.utf16)
        for statement in statements {
            #expect(String(decoding: units[statement.range], as: UTF16.self) == statement.text)
        }
    }

    @Test func statementAtCursor() {
        let script = "SELECT 1;\n\nSELECT 2;"
        #expect(SQLStatementSplitter.statement(at: 3, in: script)?.text == "SELECT 1")
        #expect(SQLStatementSplitter.statement(at: 10, in: script)?.text == "SELECT 1")
        #expect(SQLStatementSplitter.statement(at: 14, in: script)?.text == "SELECT 2")
        #expect(SQLStatementSplitter.statement(at: 0, in: "  -- only a comment") == nil)
    }
}

@Suite("Statement classification")
struct ClassificationTests {
    @Test(arguments: [
        ("SELECT 1", SQLStatementKind.query),
        ("(SELECT 1) UNION (SELECT 2)", .query),
        ("VALUES (1), (2)", .query),
        ("TABLE customers", .query),
        ("WITH a AS (SELECT 1) SELECT * FROM a", .query),
        ("WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM t WHERE n < 5) SELECT * FROM t", .query),
        ("WITH d AS (DELETE FROM t RETURNING *) SELECT count(*) FROM d", .dataModification),
        ("WITH a AS MATERIALIZED (SELECT 1), b AS (UPDATE t SET x = 1 RETURNING *) SELECT 1", .dataModification),
        ("WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a", .dataModification),
        ("SELECT * INTO new_table FROM t", .dataModification),
        ("SELECT (SELECT 1) AS x", .query),
        ("EXPLAIN SELECT 1", .explain),
        ("EXPLAIN ANALYZE DELETE FROM t", .dataModification),
        ("EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET x = 1", .dataModification),
        ("EXPLAIN (ANALYZE false) DELETE FROM t", .explain),
        ("EXPLAIN DELETE FROM t", .explain),
        ("SHOW search_path", .show),
        ("SET search_path TO app", .set),
        ("SET SESSION AUTHORIZATION bob", .administration),
        ("BEGIN", .transaction),
        ("COMMIT", .transaction),
        ("INSERT INTO t VALUES (1)", .dataModification),
        ("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE", .dataModification),
        ("COPY t TO STDOUT", .query),
        ("COPY (SELECT * FROM t) TO STDOUT WITH (FORMAT csv)", .query),
        ("COPY t (a, b) FROM STDIN", .dataModification),
        ("COPY shop.t FROM '/tmp/x.csv'", .dataModification),
        ("COPY t TO '/tmp/out.csv'", .administration),
        ("COPY t TO PROGRAM 'rm -rf /'", .administration),
        ("CALL archive_events(now())", .dataModification),
        ("DO $$ BEGIN PERFORM 1; END $$", .dataModification),
        ("REFRESH MATERIALIZED VIEW CONCURRENTLY mv", .dataModification),
        ("VACUUM (VERBOSE) t", .maintenance),
        ("CREATE INDEX CONCURRENTLY i ON t (x)", .definition),
        ("GRANT SELECT ON t TO bob", .administration),
        ("PREPARE q AS DELETE FROM t", .dataModification),
        ("PREPARE q AS SELECT 1", .query),
        ("NOTIFY jobs", .dataModification),
        ("LISTEN jobs", .set),
        ("frobnicate everything", .other),
    ])
    func classifies(sql: String, expected: SQLStatementKind) {
        #expect(SQLStatementKind.of(sql) == expected, "\(sql)")
    }

    @Test func mutationsNeedConfirmation() {
        #expect(SQLStatementKind.of("WITH d AS (DELETE FROM t RETURNING *) SELECT 1").isMutation)
        #expect(SQLStatementKind.of("frobnicate").isMutation)
        #expect(!SQLStatementKind.of("SELECT 1").isMutation)
        #expect(!SQLStatementKind.of("BEGIN").isMutation)
    }
}

@Suite("Auto LIMIT")
struct AutoLimitTests {
    @Test func appliesOnlyToTopLevelQueries() {
        #expect(AutoLimit.apply(to: "SELECT * FROM t", limit: 100).sql == "SELECT * FROM t LIMIT 100")
        #expect(AutoLimit.apply(to: "SELECT * FROM t -- note", limit: 100).sql == "SELECT * FROM t LIMIT 100 -- note")
        #expect(AutoLimit.apply(to: "SELECT * FROM t LIMIT 5", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t FETCH FIRST 5 ROWS ONLY", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM t OFFSET 10", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * FROM (SELECT * FROM t LIMIT 5) s", limit: 100).applied)
        #expect(AutoLimit.apply(to: "SELECT * FROM t FOR UPDATE", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT * INTO x FROM t", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "INSERT INTO t SELECT 1", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "EXPLAIN SELECT 1", limit: 100).applied == false)
        #expect(AutoLimit.apply(to: "SELECT 1", limit: 0).applied == false)
        #expect(AutoLimit.apply(to: "WITH a AS (SELECT 1) SELECT * FROM a", limit: 7).sql == "WITH a AS (SELECT 1) SELECT * FROM a LIMIT 7")
    }
}

@Suite("Read-only guard")
struct ReadOnlyGuardTests {
    @Test(arguments: [
        "SELECT * FROM t",
        "  select 1;  ",
        "WITH a AS (SELECT 1) SELECT * FROM a",
        "VALUES (1)",
        "TABLE customers",
        "SHOW search_path",
        "EXPLAIN SELECT 1",
        "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT * FROM t",
        "SELECT 'DELETE FROM t' AS text, $$DROP TABLE t$$ AS body /* UPDATE */ -- INSERT",
        "SELECT \"update\" FROM t",
        "SELECT pg_sleep(1)",
        "SELECT count(*) FROM pg_stat_activity",
        "SELECT to_tsvector('english', 'the delete key') @@ to_tsquery('delete')",
        "SELECT 'note: call support(now)' AS text",
        "SELECT $q$SELECT lower('x')$q$ AS sql",
    ])
    func allows(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    @Test(arguments: [
        "DELETE FROM t",
        "SELECT 1; DELETE FROM t",
        "WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d",
        "WITH a AS (SELECT 1) UPDATE t SET x = 1",
        "SELECT * INTO copy FROM t",
        "SELECT * FROM t FOR UPDATE",
        "SELECT * FROM t FOR NO KEY UPDATE",
        "SELECT pg_terminate_backend(123)",
        "SELECT pg_catalog.pg_cancel_backend(123)",
        "SELECT set_config('search_path', 'x', false)",
        "SELECT pg_advisory_lock(1)",
        "SELECT nextval('s')",
        "SELECT dblink_exec('host=x', 'DROP TABLE t')",
        "SELECT query_to_xml('DELETE FROM t RETURNING *', true, false, '')",
        "SELECT lo_import('/etc/passwd')",
        "SELECT pg_read_file('/etc/passwd')",
        "SELECT \"pg_terminate_backend\"(1)",
        "SELECT U&\"pg\\005fread_file\"('/etc/passwd')",
        "SELECT pg_catalog.pg_reload_conf()",
        "SELECT \"pg_reload_conf\"()",
        "SELECT pg_rotate_logfile()",
        "SELECT pg_switch_wal()",
        "SELECT pg_create_restore_point('x')",
        "SELECT pg_logical_emit_message(true, 'p', 'x')",
        "SELECT pg_replication_origin_create('o')",
        "SELECT pg_stat_reset_shared('bgwriter')",
        "SELECT pg_promote()",
        "SELECT pg_wal_replay_pause()",
        "SELECT lo_export(1, '/tmp/x')",
        "SELECT lo_unlink(1)",
        "SELECT pg_file_write('x', 'y', false)",
        "SELECT pg_read_binary_file('/etc/passwd')",
        "SELECT pg_ls_dir('.')",
        "SELECT pg_notify('c', 'x')",
        "SELECT * FROM pg_create_physical_replication_slot('s')",
        "COPY (SELECT 1) TO PROGRAM 'touch /tmp/x'",
        "COPY (SELECT 1) TO '/tmp/x'",
        "NOTIFY c, 'x'",
        "COMMIT",
        "ROLLBACK",
        "SAVEPOINT a",
        "RELEASE a",
        "START TRANSACTION",
        "PREPARE TRANSACTION 'x'",
        "SET TRANSACTION READ WRITE",
        "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE",
        "SET default_transaction_read_only = off",
        "EXPLAIN ANALYZE DELETE FROM t",
        "EXPLAIN DELETE FROM t",
        "COPY t TO STDOUT",
        "CALL p()",
        "DO $$ BEGIN DELETE FROM t; END $$",
        "SET search_path TO x",
        "BEGIN",
        "VACUUM t",
        "NOTIFY x",
        "PREPARE q AS SELECT 1",
        "",
        "-- just a comment",
        // Review finding 1: functions that run SQL given as text, and calls hidden inside literals.
        "SELECT * FROM ts_stat($q$SELECT to_tsvector(pg_terminate_backend(pid)::text) FROM pg_stat_activity$q$)",
        "SELECT * FROM ts_stat('SELECT to_tsvector(pg_advisory_lock(424242)::text)')",
        "SELECT * FROM pg_catalog.ts_stat('SELECT to_tsvector(''x'')')",
        "SELECT ts_rewrite('a'::tsquery, 'SELECT ''a''::tsquery, ''b''::tsquery')",
        "SELECT * FROM crosstab('SELECT 1, 2, 3') AS t(a int, b int)",
        "SELECT * FROM run_command_on_workers('SELECT pg_reload_conf()')",
        "SELECT pg_background_launch('VACUUM')",
        "SELECT my_exec('SELECT pg_terminate_backend(1)')",
        "SELECT my_exec($$SELECT pg_catalog.pg_reload_conf ()$$)",
        "SELECT my_exec(E'SELECT pg_notify(\\'c\\', \\'x\\')')",
        "SELECT my_exec('SELECT f(''SELECT \"pg_read_file\"(/etc/passwd)'')')",
        "SELECT pg_reload_conf/**/()",
    ])
    func rejects(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }
}

@Suite("Redaction")
struct RedactorTests {
    @Test func removesCredentials() {
        #expect(SQLRedactor.redact("ALTER ROLE app PASSWORD 'secret'") == "ALTER ROLE app PASSWORD '***'")
        #expect(SQLRedactor.redact("CREATE USER x WITH ENCRYPTED PASSWORD 'p@ss' VALID UNTIL '2030-01-01'")
            == "CREATE USER x WITH ENCRYPTED PASSWORD '***' VALID UNTIL '2030-01-01'")
        #expect(SQLRedactor.redact("CREATE USER MAPPING FOR bob SERVER s OPTIONS (user 'bob', password 'hunter2')")
            == "CREATE USER MAPPING FOR bob SERVER s OPTIONS (user 'bob', password '***')")
        #expect(SQLRedactor.redact("CREATE SERVER s FOREIGN DATA WRAPPER x OPTIONS (aws_secret_access_key 'abc')")
            == "CREATE SERVER s FOREIGN DATA WRAPPER x OPTIONS (aws_secret_access_key '***')")
        #expect(SQLRedactor.redact("SET app.api_token = 'zzz'") == "SET app.api_token = '***'")
        #expect(SQLRedactor.redact("SELECT dblink_connect('host=db user=a password=topsecret dbname=x')")
            == "SELECT dblink_connect('host=db user=a password=*** dbname=x')")
        #expect(SQLRedactor.redact("CREATE SUBSCRIPTION s CONNECTION 'postgresql://rep:pw123@db/app' PUBLICATION p")
            == "CREATE SUBSCRIPTION s CONNECTION 'postgresql://rep:***@db/app' PUBLICATION p")
        #expect(SQLRedactor.redact("ALTER ROLE app PASSWORD $$secret$$") == "ALTER ROLE app PASSWORD $$***$$")
        #expect(SQLRedactor.redact("SELECT 'password' AS label, 1") == "SELECT 'password' AS label, 1")
        #expect(SQLRedactor.redact("SELECT * FROM t WHERE name = 'bob'") == "SELECT * FROM t WHERE name = 'bob'")
    }
}

@Suite("Error positions")
struct ErrorLocatorTests {
    @Test func positionsCountCodePoints() {
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT x", position: 8) == 7)
        // 𝔸 is one code point but two UTF-16 units.
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT '𝔸', bad", position: 13) == 13)
        #expect(SQLErrorLocator.highlightRange(in: "SELECT 'é', missing FROM t", position: 13) == 12..<19)
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT", position: 999) == 6)
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT", position: 0) == nil)
        #expect(SQLErrorLocator.highlightRange(in: "", position: 1) == 0..<0)
    }
}
