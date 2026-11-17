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
        let tokens = kinds("SELECT 1.5e3, .5, 1_000, 0x1F, 0o17, 0b1, a.b, c->>'k', d @> e, f::text[], g!=h, i#-j")
        #expect(tokens.filter { $0.0 == .number }.map(\.1) == ["1.5e3", ".5", "1_000", "0x1F", "0o17", "0b1"])
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "->>" })
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "@>" })
        #expect(tokens.contains { $0.0 == .operator && $0.1 == "!=" })
        #expect(tokens.contains { $0.0 == .punctuation && $0.1 == "[" })
    }

    // PostgreSQL ends an operator before trailing `+`/`-` unless it contains one of ~ ! @ # % ^ & | ` ? (scan.l), so
    // `a=-1` is `=` then `-`: the formatter relies on the same token boundaries as the server.
    @Test func operatorsDropTrailingSignsLikeTheServer() {
        let operators = { (sql: String) in self.kinds(sql).filter { $0.0 == .operator }.map(\.1) }
        #expect(operators("a=-1") == ["=", "-"])
        #expect(operators("b*-1") == ["*", "-"])
        #expect(operators("c>=-2") == [">=", "-"])
        #expect(operators("d+-+e") == ["+", "-", "+"])
        #expect(operators("x@-1") == ["@-"])
        #expect(operators("i#-j") == ["#-"])
        #expect(operators("k->>'a'") == ["->>"])
        #expect(operators("l - -m") == ["-", "-"])
    }

    /// Token texts of `sql` with a server version's number syntax.
    private func texts(_ sql: String, _ numbers: SQLLexer.Syntax) -> [String] {
        let lexer = SQLLexer(sql, syntax: numbers)
        return lexer.tokens().map { lexer.text(of: $0) }
    }

    /// Recorded from `SELECT <input>` on PostgreSQL 13 (column label and value) and 17/18 (the error's "at or near" token);
    /// the integration tests repeat the comparison on every tested server.
    static let numberCases: [(input: String, postgres14: [String], postgres16: [String])] = [
        ("123abc", ["123", "abc"], ["123abc"]),
        ("123e", ["123", "e"], ["123e"]),
        ("1e+x", ["1", "e", "+", "x"], ["1e+", "x"]),
        ("1e5x", ["1e5", "x"], ["1e5x"]),
        ("1e+5x", ["1e+5", "x"], ["1e+5x"]),
        ("1.5x", ["1.5", "x"], ["1.5x"]),
        ("1.x", ["1.", "x"], ["1.x"]),
        ("1.e5", ["1.e5"], ["1.e5"]),
        (".5x", [".5", "x"], [".5x"]),
        ("0x1F", ["0", "x1F"], ["0x1F"]),
        ("0X1f", ["0", "X1f"], ["0X1f"]),
        ("0x1Fg", ["0", "x1Fg"], ["0x1Fg"]),
        ("0x", ["0", "x"], ["0x"]),
        ("0x_1F", ["0", "x_1F"], ["0x_1F"]),
        ("0x1F_", ["0", "x1F_"], ["0x1F_"]),
        ("0o17", ["0", "o17"], ["0o17"]),
        ("0o19", ["0", "o19"], ["0o19"]),
        ("0b101", ["0", "b101"], ["0b101"]),
        ("0b12", ["0", "b12"], ["0b12"]),
        ("0b_1", ["0", "b_1"], ["0b_1"]),
        ("0or", ["0", "or"], ["0or"]),
        ("00x1", ["00", "x1"], ["00x1"]),
        ("1_000", ["1", "_000"], ["1_000"]),
        ("1__000", ["1", "__000"], ["1__000"]),
        ("1_", ["1", "_"], ["1_"]),
        ("1_000.5_5", ["1", "_000", ".5", "_5"], ["1_000.5_5"]),
        ("1e1_0", ["1e1", "_0"], ["1e1_0"]),
        ("1e_10", ["1", "e_10"], ["1e_10"]),
        ("1._5", ["1.", "_5"], ["1._5"]),
        ("1_.5", ["1", "_", ".5"], ["1_", ".5"]),
        ("1..2", ["1", "..", "2"], ["1", "..", "2"]),
        ("1_0..2", ["1", "_0", "..", "2"], ["1_0", "..", "2"]),
        ("a.5", ["a", ".5"], ["a", ".5"]),
        ("1.5.5", ["1.5", ".5"], ["1.5", ".5"]),
        ("0x1F.x", ["0", "x1F", ".", "x"], ["0x1F", ".", "x"]),
        (".e5", [".", "e5"], [".", "e5"]),
        ("123a$b", ["123", "a$b"], ["123a$b"]),
        ("123é", ["123", "é"], ["123é"]),
        ("$1abc", ["$1", "abc"], ["$1abc"]),
        ("$1_0", ["$1", "_0"], ["$1_0"]),
        ("$1.5", ["$1", ".5"], ["$1", ".5"]),
        ("$01", ["$01"], ["$01"]),
    ]

    // PostgreSQL 15 rejects a word written right after a number ("trailing junk"); 16 adds `0x` / `0o` / `0b` literals and
    // `_` between digits. The lexer follows each version exactly, so the formatter can check its output against both.
    @Test func numbersFollowEachServerVersion() {
        for (input, postgres14, postgres16) in Self.numberCases {
            #expect(texts(input, .postgres14) == postgres14, "PostgreSQL 14: \(input)")
            #expect(texts(input, .postgres16) == postgres16, "PostgreSQL 16: \(input)")
        }
        let junk = SQLLexer("select 123abc, $1abc", syntax: .postgres16).tokens()
        #expect(junk.map(\.kind) == [.keyword, .number, .punctuation, .parameter])
        #expect(SQLLexer("..", syntax: .postgres14).tokens().map(\.kind) == [.punctuation])
    }

    // The editor's syntax: 16's literals, and a word after a number is its own token (as before 15), so a keyword any server
    // version sees is a keyword here too (the read-only guard relies on it).
    @Test func theEditorSeesEveryKeywordAnyVersionSees() {
        #expect(texts("0x1F 1_000 1e1_0 0b_1", .editor) == ["0x1F", "1_000", "1e1_0", "0b_1"])
        #expect(texts("123abc $1abc 0or 0x 1__000 1e+x 0o19", .editor)
            == ["123", "abc", "$1", "abc", "0", "or", "0", "x", "1", "__000", "1", "e", "+", "x", "0o1", "9"])
        #expect(SQLLexer("select 1").syntax == .editor, "the default")
        // 16+ rejects trailing junk and failed exponents (`1E-` in `1E--x`, where 13 reads `1`, `E` and a comment): text it
        // does not accept is compared with 14's reading only (the guard reads every version anyway).
        #expect(texts("1E--x", .postgres16) == ["1E-", "-", "x"])
        #expect(texts("1E--x", .editor) == ["1", "E", "--x"])
        let pieces = ["0", "1", "9", "x", "o", "b", "e", "E", "_", ".", "+", "-", "$", "or", "for", "from", "as", "abc", " ", "é", "f"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20_000 {
            let text = (0..<Int.random(in: 1...12, using: &generator)).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
            let editorTokens = SQLLexer(text).tokens()
            let editor = Set(editorTokens.filter { $0.kind == .keyword }.map(\.range))
            let editorRanges = Set(editorTokens.map(\.range))
            for syntax in SQLLexer.Syntax.servers {
                let tokens = SQLLexer(text, syntax: syntax).tokens()
                // A 16+ number or parameter the editor does not also see is an invalid one (junk, `1e+`, `0x`).
                let accepted = !syntax.joinsTrailingWords
                    || tokens.allSatisfy { ($0.kind != .number && $0.kind != .parameter) || editorRanges.contains($0.range) }
                guard accepted else { continue }
                let keywords = tokens.filter { $0.kind == .keyword }.map(\.range)
                #expect(keywords.allSatisfy(editor.contains), "\(text.debugDescription)")
            }
        }
    }

    // PostgreSQL folds only ASCII letters: to a server, a word with any other character is a name (`ﬁrst` is not FIRST, the
    // integration tests check it on every version). The editor's syntax, which the read-only guard uses, counts every case
    // mapping instead: it must never see fewer keywords than a reader that folds more.
    @Test func keywordFoldingPerSyntax() {
        let words = "ﬁrst ﬆatement ſelect ınto diﬆinct First"
        for syntax in SQLLexer.Syntax.servers {
            #expect(SQLLexer(words, syntax: syntax).tokens().map(\.kind) == [.identifier, .identifier, .identifier, .identifier, .identifier, .keyword])
            let lexer = SQLLexer("ﬁrst", syntax: syntax)
            #expect(lexer.word(of: lexer.tokens()[0]) == "ﬁRST", "only ASCII letters change case")
        }
        #expect(kinds(words).map(\.0) == [.keyword, .keyword, .keyword, .keyword, .keyword, .keyword])
        let editor = SQLLexer("ınto")
        #expect(editor.word(of: editor.tokens()[0]) == "INTO")
    }

    // The server reads a whole run of operator characters ("operator too long" past 63), bit strings end at their first
    // quote (`B'10''01'` is two literals), and with standard_conforming_strings off a backslash escapes a quote in '…'.
    @Test func operatorsBitStringsAndNonConformingStrings() {
        let run = String(repeating: "@", count: 70) + "-"
        #expect(kinds("select 1 \(run)2").filter { $0.0 == .operator }.map(\.1) == [run])
        #expect(kinds("select B'10''01', X'1F''2E', b'1'").filter { $0.0 == .string }.map(\.1) == ["B'10'", "'01'", "X'1F'", "'2E'", "b'1'"])
        let open = SQLLexer("B'1''")
        #expect(open.unterminated(open.tokens()[1]) != nil, "the second literal is open")
        let off = SQLLexer.Syntax.postgres16.with(standardConformingStrings: false)
        #expect(texts("select 'don\\'t   panic', N'a\\'b', E'c\\'d', B'1'", off)
            == ["select", "'don\\'t   panic'", ",", "N'a\\'b'", ",", "E'c\\'d'", ",", "B'1'"])
        #expect(texts("select 'don\\'t   panic'", .postgres16) == ["select", "'don\\'", "t", "panic", "'"])
        #expect(SQLLexer.Syntax.servers.allSatisfy { $0.standardConformingStrings })
    }

    @Test func identifierValuesFoldCase() {
        let lexer = SQLLexer("Users \"Users\" U&\"x\"")
        let tokens = lexer.tokens()
        #expect(lexer.identifierValue(of: tokens[0]) == "users")
        #expect(lexer.identifierValue(of: tokens[1]) == "Users")
        #expect(lexer.identifierValue(of: tokens[2]) == "x")
    }

    @Test func unterminatedInputNeverTraps() {
        for sql in ["'abc", "$$abc", "$tag$ abc $ta", "/* /* */", "\"abc", "E'\\", "U&", "$", "$1a", "0x", "0x_", "1e", "1e+", "1_", ".", "..", "::"] {
            _ = SQLLexer.tokenize(sql)
            for syntax in SQLLexer.Syntax.servers { _ = SQLLexer(sql, syntax: syntax).tokens() }
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
            _ = SQLErrorLocator.range(in: text, error: SQLServerError(message: "x", position: Int.random(in: -2..<80, using: &generator)))
            _ = SQLLinter.diagnose(text)
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

    // `BEGIN ATOMIC` opens a body only in CREATE [OR REPLACE] FUNCTION / PROCEDURE; anywhere else its `;` end statements,
    // as they do for the server.
    @Test func atomicBodiesOnlyInRoutines() {
        #expect(SQLStatementSplitter.split("SELECT begin atomic FROM (SELECT 1 AS begin) s; COMMIT; SET a = 1; END").map(\.text)
            == ["SELECT begin atomic FROM (SELECT 1 AS begin) s", "COMMIT", "SET a = 1", "END"])
        #expect(SQLStatementSplitter.split("SHOW x begin atomic; SET a = 1; end").count == 3)
        #expect(SQLStatementSplitter.split("CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END; SELECT 3")
            .map(\.text) == ["CREATE OR REPLACE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END", "SELECT 3"])
        #expect(SQLStatementSplitter.split("create procedure p() begin atomic select 1; end; select 2").count == 2)
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
        "SELECT 'hello' AS text, $$plain words$$ AS body /* UPDATE */ -- INSERT",
        "SELECT 'Select a plan' AS label, 'Show more' AS more",
        "SELECT $q$SELECT lower('x') FROM t$q$ AS sql",
        "SELECT E'tab\\there' AS escaped, U&'d\\0061ta' AS unicode, B'1010' AS bits, X'1F' AS hex",
        "SELECT \"update\" FROM t",
        "SELECT pg_sleep(1)",
        "SELECT count(*) FROM pg_stat_activity",
        "SELECT to_tsvector('english', 'the delete key') @@ to_tsquery('removal')",
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
        // Lead review: inner SQL is checked recursively by the whole guard, whatever function receives it.
        "SELECT 'DELETE FROM t' AS text",
        "SELECT my_exec($$DELETE FROM t$$)",
        "SELECT my_exec($body$ INSERT INTO t VALUES (1) $body$)",
        "SELECT my_exec('SELECT my_exec(''DELETE FROM t'')')",
        "SELECT my_exec('SELECT my_exec($x$UPDATE t SET a = 1$x$)')",
        "SELECT my_exec('SELECT 1; DELETE FROM t')",
        "SELECT my_exec('BEGIN PERFORM 1; END')",
        "SELECT my_exec('SELECT * FROM t FOR UPDATE')",
        "SELECT my_exec(E'\\x44ELETE FROM t')",
        "SELECT my_exec(E'\\104ELETE FROM t')",
        "SELECT my_exec(E'SELECT pg\\u005fterminate_backend(1)')",
        "SELECT my_exec(U&'\\0044ELETE FROM t')",
        "SELECT my_exec(U&'!0044ELETE FROM t' UESCAPE '!')",
        "SELECT my_exec('DEL'\n'ETE FROM t')",
        "SELECT my_exec('x := pg_terminate_backend(1)')",
        // Conservative by design: a literal that is a write verb is refused even as plain data.
        "SELECT to_tsquery('delete')",
    ])
    func rejects(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    /// The lexer is a security boundary: where PostgreSQL versions (or settings) could read a text differently, the guard
    /// takes the reading that sees more. Each of these hides a second statement, `SELECT … INTO` (which creates a table)
    /// or `COPY … TO PROGRAM` behind such a construct; every one is refused.
    @Test(arguments: [
        // A word right after a number: PostgreSQL 13–14 read `1.5 INTO t` (and create table t), 15+ reject trailing junk.
        "SELECT 1.5into t", "SELECT 1into t", "SELECT 1e2into t", "SELECT .5into t", "SELECT 1.into t", "SELECT 1e+5into t",
        "SELECT 0x1Finto t", "SELECT 0b1into t", "SELECT 1_000into t", "SELECT $1into t", "SELECT 1for update",
        "SELECT * FROM t LIMIT 1for share",
        // PostgreSQL folds only ASCII letters, but the guard reads every case mapping (`ınto` upper-cases to INTO).
        "SELECT 1 ınto t", "SELECT 1 ıNTO t", "create table if not exiſts t (a int)",
        // Semicolons the splitter keeps inside a statement (`BEGIN ATOMIC` bodies, parentheses) never pass in a query.
        "SELECT x.begin atomic FROM (SELECT 1 AS begin) x; SET search_path = evil; end",
        "SELECT (1; COPY t TO PROGRAM 'id')",
        // Dollar quotes: a string to PostgreSQL, but its content holds a second statement.
        "SELECT 1 $$a; DROP TABLE t -- $$", "SELECT $a$ x $A$; COPY t TO PROGRAM 'id'; $a$", "SELECT $1$a$; DROP TABLE t; $a$",
        "SELECT a$b$; DROP TABLE t; $b$",
        // Backslashes: always escapes in E'…'; in '…' only while standard_conforming_strings is off (`'a\''` ends early).
        "SELECT E'\\''; DROP TABLE t; --'", "SELECT 'a\\'; DROP TABLE t; --'", "SELECT 'a\\'';DROP TABLE t;--'",
        "SELECT N'a\\'';COPY t TO PROGRAM 'id';--'",
        // Nested block comments: one comment to PostgreSQL, code to a reader that ends it at the first `*/`.
        "SELECT 1 /* /* */ ; DROP TABLE t; */", "SELECT 1 /* /* */ INTO t */",
        // Unicode escapes can spell any quote or name.
        "SELECT U&'!0027; DROP TABLE t; --' UESCAPE '!'", "SELECT U&\"!0064rop\" UESCAPE '!'",
        // Read as PostgreSQL 13 does: `1`, `_0e`, and a '…' string with a backslash before its quote (to the editor's reading
        // an E'…' string after `1_0`). Every reading must allow a statement.
        "SELECT 1_0e'a\\'' AS x",
        // Review: a literal whose first statement is empty (`;COPY …`) is SQL too; every statement in it is checked.
        "SELECT zz_exec(';COPY (SELECT 1) TO PROGRAM ''exit 7''')", "SELECT zz_exec('(SELECT 1); COPY (SELECT 1) TO PROGRAM ''x''')",
        "SELECT zz_exec(E';\\nCOPY (SELECT 1) TO PROGRAM \\'x\\'')", "SELECT zz_exec($$ ; ; copy (select 1) to program 'x' $$)",
        "SELECT zz_exec('(COPY (SELECT 1) TO PROGRAM ''x'')')",
        // TO / FROM PROGRAM anywhere, in any case, literals included (defence in depth).
        "SELECT zz_exec('x tO pRoGrAm ''id''')", "SELECT 'copy t from program ''id'''", "SELECT zz_exec('to /* c */ program')",
        // BEGIN ATOMIC is never part of a read.
        "SELECT x.begin atomic FROM (SELECT 1 AS begin) x", "SHOW x begin atomic; SET a = 1; end",
        // Line comments end at `\r` as well as `\n`.
        "SELECT 1 -- x\r; DROP TABLE t", "SELECT 1 --\rINTO t",
    ])
    func refusesWhatAnyReadingSeesAsAWrite(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    // Those rules stay narrow: ordinary backslashes, comments and numbers still pass.
    @Test(arguments: [
        "SELECT 'C:\\dir', regexp_matches(x, '\\d+') FROM t", "SELECT E'it\\'s' AS e", "SELECT 1 /* one comment */ + 2",
        "SELECT 1.5 AS x, 0x1F, 1_000, 1e5", "SELECT ﬁrst FROM t",
    ])
    func allowsOrdinaryLookalikes(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription)")
    }

    // What the PgBouncer admin console path may send over the simple protocol: exactly one statement.
    @Test func singleStatementsForTheSimpleProtocol() {
        #expect(ReadOnlySQLGuard.isSingleStatement("SHOW POOLS"))
        #expect(ReadOnlySQLGuard.isSingleStatement("SHOW ';' /* ; */"))
        #expect(!ReadOnlySQLGuard.isSingleStatement("SHOW POOLS; RELOAD"))
        #expect(!ReadOnlySQLGuard.isSingleStatement("SHOW x begin atomic; RELOAD; end"))
        #expect(!ReadOnlySQLGuard.isSingleStatement("SHOW POOLS;"))
    }
}

@Suite("Read-only guard literal decoding")
struct LiteralDecodingTests {
    /// `SELECT f('…')` around `sql`, quoting it like PostgreSQL.
    private func nested(_ sql: String, levels: Int) -> String {
        (0..<levels).reduce(sql) { inner, _ in "SELECT f('" + inner.replacingOccurrences(of: "'", with: "''") + "')" }
    }

    @Test func innerSQLIsCheckedAtEveryLevelUpToTheLimit() {
        #expect(ReadOnlySQLGuard.check(nested("SELECT 1", levels: 3)) == nil)
        #expect(ReadOnlySQLGuard.check(nested("DELETE FROM t", levels: 2)) != nil)
        #expect(ReadOnlySQLGuard.check(nested("DELETE FROM t", levels: 4)) != nil)
        #expect(ReadOnlySQLGuard.check(nested("SELECT pg_terminate_backend(1)", levels: 3)) != nil)
        // Deeper than the limit is refused even when harmless.
        #expect(ReadOnlySQLGuard.check(nested("SELECT 1", levels: ReadOnlySQLGuard.maxLiteralDepth + 1)) != nil)
    }

    @Test func decodesLiteralsAsPostgreSQLReadsThem() {
        #expect(ReadOnlySQLGuard.literalContent("'it''s'") == "it's")
        #expect(ReadOnlySQLGuard.literalContent("'a\\b'") == "a\\b") // standard_conforming_strings = on
        #expect(ReadOnlySQLGuard.literalContent("E'it\\'s\\n\\x41\\101\\u00e9\\U0001F600\\q'") == "it's\nAAé😀q")
        #expect(ReadOnlySQLGuard.literalContent("e'\\\\'") == "\\")
        #expect(ReadOnlySQLGuard.literalContent("U&'d\\0061t\\+000061 \\\\ \\D83D\\DE00'") == "data \\ 😀")
        #expect(ReadOnlySQLGuard.literalContent("$tag$ x $ y $tag$") == " x $ y ")
        #expect(ReadOnlySQLGuard.literalContent("$$unterminated") == "unterminated")
        #expect(ReadOnlySQLGuard.literalContent("N'national'") == "national")
        #expect(ReadOnlySQLGuard.literalContent("B'1010'") == nil)
        #expect(ReadOnlySQLGuard.literalContent("X'1F'") == nil)
        // Malformed escapes never trap.
        for literal in ["E'\\", "E'\\x'", "E'\\u12'", "E'\\U'", "U&'\\'", "U&'\\+12'", "U&'\\DC00'", "'", "E'", "$"] {
            _ = ReadOnlySQLGuard.literalContent(literal)
        }
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

