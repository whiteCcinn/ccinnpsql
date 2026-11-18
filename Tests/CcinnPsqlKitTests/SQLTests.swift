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

    @Test func fuzzedInputNeverTraps() async {
        // Seconds of work in debug builds: on a thread of its own, so the rest of the suite keeps its threads.
        await onDedicatedThread { Self.fuzzEveryEntryPoint() }
    }

    private static func fuzzEveryEntryPoint() {
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
    // A statement that ends inside an unterminated string, quoted identifier or dollar quote stays as written: the clause
    // would land inside it and change how the statement's own text lexes.
    @Test func neverAppendsInsideAnUnterminatedToken() {
        for sql in ["SELECT a FROM t WHERE b = 'x", "SELECT \"a FROM t", "SELECT $$ a FROM t", "SELECT a FROM t'", "SELECT E'\\'"] {
            #expect(AutoLimit.apply(to: sql, limit: 10).applied == false, "\(sql)")
        }
        #expect(AutoLimit.apply(to: "SELECT a FROM t /* open", limit: 10).sql == "SELECT a FROM t LIMIT 10 /* open")
    }

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
        "SELECT 1.5 AS x, 0x1F, 1_000, 1e5",
    ])
    func allowsOrdinaryLookalikes(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql.debugDescription)")
    }

    // The guard checks exactly what is sent: a NUL anywhere is refused (it split names and keywords while the transport
    // stripped it: `pg_read\0_file`, `IN\0TO`), inside literals too.
    @Test(arguments: ["SELECT pg_read\u{0}_file('/etc/hostname')", "SELECT count(*) FROM pg_ls\u{0}_dir('.')", "SELECT 1 IN\u{0}TO zz_t",
                      "SELECT pg_terminate\u{0}_backend(1)", "SELECT set\u{0}_config('a', 'b', false)", "SELECT zz_exec('CO\u{0}PY (SELECT 1) TO PROGRAM ''x''')",
                      "SELECT 1 -- \u{0}", "\u{0}"])
    func refusesNulCharacters(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql)?.contains("NUL") == true, "\(sql.debugDescription)")
    }

    // Sources of other sessions' SQL text or of credentials: only through the redacted tools (get_activity,
    // get_top_statements).
    @Test(arguments: ["SELECT query FROM pg_stat_activity", "SELECT count(*) FROM pg_catalog.pg_stat_activity", "SELECT * FROM pg_stat_get_activity(NULL)",
                      "SELECT pg_stat_get_backend_activity(1)", "SELECT query FROM pg_stat_statements", "SELECT * FROM public.pg_stat_statements(true)",
                      "SELECT rolpassword FROM pg_authid", "SELECT passwd FROM pg_shadow", "SELECT umoptions FROM pg_user_mappings",
                      "SELECT * FROM pg_user_mapping", "SELECT * FROM pg_file_settings", "SELECT subconninfo FROM pg_subscription",
                      "SELECT * FROM \"pg_stat_activity\"", "SELECT pg_stat_file('postgresql.conf')",
                      // Views, tables and functions found by enumerating pg_catalog on every version (integration test).
                      "SELECT conninfo FROM pg_stat_wal_receiver", "SELECT * FROM pg_stat_get_wal_receiver()", "SELECT * FROM pg_stat_replication",
                      "SELECT options FROM pg_hba_file_rules", "SELECT * FROM pg_hba_file_rules()", "SELECT * FROM pg_ident_file_mappings",
                      "SELECT srvoptions FROM pg_foreign_server", "SELECT ftoptions FROM pg_foreign_table", "SELECT fdwoptions FROM pg_foreign_data_wrapper",
                      "SELECT setconfig FROM pg_db_role_setting", "SELECT * FROM pg_show_all_file_settings()", "SELECT pg_current_logfile()",
                      "SELECT * FROM pg_stat_statements_info", "SELECT lo_get(42)", "SELECT * FROM pg_largeobject",
                      "SELECT pg_stat_get_backend_activity(s) FROM pg_stat_get_backend_idset() s"])
    func refusesSourcesOfOtherSessionsSQLAndCredentials(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Built-ins that read a relation chosen at run time or run SQL from a string: the review read a user-mapping password
    // through `table_to_xml(c.oid::regclass …)` with the name built at run time, which no name blocklist can see.
    @Test(arguments: ["SELECT table_to_xml(c.oid::regclass, true, false, '') FROM pg_class c WHERE c.relname = 'pg_user_' || 'mappings'",
                      "SELECT pg_catalog.table_to_xml('pg_stat_' || 'activity', true, false, '')", "SELECT table_to_xmlschema('t', true, false, '')",
                      "SELECT table_to_xml_and_xmlschema('t', true, false, '')", "SELECT schema_to_xml('public', true, false, '')",
                      "SELECT schema_to_xmlschema('public', true, false, '')", "SELECT schema_to_xml_and_xmlschema('public', true, false, '')",
                      "SELECT database_to_xml(true, false, '')", "SELECT database_to_xmlschema(true, false, '')",
                      "SELECT database_to_xml_and_xmlschema(true, false, '')", "SELECT \"table_to_xml\"('t', true, false, '')",
                      "SELECT cursor_to_xmlschema('c', true, false, '')", "SELECT * FROM ts_stat('SELECT 1')",
                      "SELECT pg_clear_relation_stats('public', 't')", "SELECT pg_restore_relation_stats('relation', 't')",
                      // Every *_to_xml* variant (query, table, schema, database, cursor; _xmlschema and _and_xmlschema) and ts_stat /
                      // ts_rewrite at any arity: the check is by name.
                      "SELECT query_to_xml('SELECT 1', true, false, '')", "SELECT query_to_xmlschema('SELECT 1', true, false, '')",
                      "SELECT query_to_xml_and_xmlschema('SELECT 1', true, false, '')", "SELECT cursor_to_xml('c', 1, true, false, '')",
                      "SELECT pg_catalog.cursor_to_xml('c', 1, true, false, '')", "SELECT \"query_to_xml\"('SELECT 1', true, false, '')",
                      "SELECT * FROM ts_stat('SELECT v FROM t', 'ab')", "SELECT ts_rewrite(q, 'SELECT a, b FROM r') FROM t",
                      "SELECT ts_rewrite(q, 'a'::tsquery, 'b'::tsquery) FROM t", "SELECT ts_rewrite(ARRAY[q, 'a', 'b']) FROM t"])
    func refusesRunTimeRelationAndSQLReaders(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Writes a READ ONLY transaction does not stop (BRIN summarisation and GIN pending-list cleanup change index pages), and
    // functions whose effects outlive the transaction or reach other sessions, at any arity and however they are spelled.
    @Test(arguments: ["SELECT brin_summarize_new_values('t_brin')", "SELECT brin_summarize_range('t_brin', 0)",
                      "SELECT brin_desummarize_range('t_brin', 0)", "SELECT gin_clean_pending_list('t_gin')",
                      "SELECT pg_catalog.brin_summarize_new_values('t_brin'::regclass)", "SELECT \"gin_clean_pending_list\"('t_gin')",
                      "SELECT pg_cancel_backend(1)", "SELECT pg_terminate_backend(1, 100)", "SELECT pg_reload_conf()", "SELECT pg_rotate_logfile()",
                      "SELECT pg_rotate_logfile_old()", "SELECT pg_switch_wal()", "SELECT pg_create_restore_point('x')", "SELECT pg_stat_reset()",
                      "SELECT pg_stat_reset_slru('x')", "SELECT pg_stat_reset_backend_stats(1)", "SELECT pg_advisory_lock_shared(1)",
                      "SELECT pg_try_advisory_lock(1, 2)", "SELECT pg_try_advisory_xact_lock_shared(1)", "SELECT set_config('a.b', 'c', false)",
                      "SELECT set_config('a.b', 'c', true)", "SELECT setseed(0.5)", "SELECT pg_log_standby_snapshot()", "SELECT pg_nextoid('t', 'c', 'i')",
                      "SELECT pg_stop_making_pinned_objects()", "SELECT pg_extension_config_dump('t', '')", "SELECT pg_stat_force_next_flush()",
                      "SELECT binary_upgrade_set_next_pg_type_oid(1)", "SELECT loread(0, 10)", "SELECT pg_import_system_collations('pg_catalog')",
                      // Extensions that write past READ ONLY (pg_surgery, pg_visibility).
                      "SELECT heap_force_kill('t', ARRAY['(0,1)'::tid])", "SELECT heap_force_freeze('t', ARRAY['(0,1)'::tid])",
                      "SELECT pg_truncate_visibility_map('t')"])
    func refusesWritesReadOnlyDoesNotStop(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Role and database settings can hold secrets (`ALTER ROLE app SET myapp.api_key = '…'`): the catalogs that list them
    // (`SELECT *` on pg_roles or pg_user includes rolconfig / useconfig), and lookups of custom (dotted) parameters. Every
    // custom parameter's name has a dot; current_setting() takes one literal name, so a name built at run time is refused too.
    @Test(arguments: ["SELECT setconfig FROM pg_db_role_setting", "SELECT rolconfig FROM pg_roles", "SELECT * FROM pg_roles", "TABLE pg_roles",
                      "SELECT r FROM pg_roles r", "SELECT to_json(r) FROM pg_catalog.pg_roles r", "SELECT useconfig FROM pg_user", "SELECT * FROM pg_user",
                      "SELECT x.rolconfig FROM my_roles x", "SELECT \"useconfig\" FROM my_users",
                      "SELECT * FROM pg_settings", "SELECT setting FROM pg_settings WHERE name = 'work_mem'", "SELECT * FROM pg_show_all_settings()",
                      "SELECT * FROM pg_track_settings_history", "SHOW ALL", "show all", "SHOW myapp.api_key", "SHOW \"myapp.api_key\"", "SHOW myapp.\"api_key\"",
                      "SHOW myapp . api_key", "SHOW /* c */ myapp.api_key", "EXPLAIN SELECT current_setting('myapp.api_key')",
                      "SELECT current_setting('myapp.api_key')", "SELECT current_setting('myapp.api_key', true)", "SELECT pg_catalog.current_setting('myapp.api_key')",
                      "SELECT \"current_setting\"('myapp.api_key')", "SELECT current_setting('myapp' || '.api_key')", "SELECT current_setting(name) FROM t",
                      "SELECT current_setting(E'myapp\\x2eapi_key')", "SELECT current_setting(U&'myapp\\002eapi_key')", "SELECT current_setting($$myapp.api_key$$)",
                      "SELECT current_setting('myapp'\n'.api_key')", "SELECT current_setting('work_mem'::text)", "SELECT current_setting(('work_mem'))",
                      "SELECT current_setting()", "SELECT current_setting(VARIADIC ARRAY['myapp.api_key'])",
                      "SELECT current_setting(setting_name => 'myapp.api_key')", "SELECT current_setting ('myapp.api_key')",
                      "SELECT f(current_setting('myapp.api_key'))", "SELECT zz_exec('SELECT current_setting(''myapp.api_key'')')"])
    func refusesSettingsThatCanHoldSecrets(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    // SHOW takes exactly one plain, unquoted, undotted ASCII name (every built-in parameter is one). The review read a database
    // and a role secret through U&-escaped names (`\002e` is a dot), which only the SELECT path refused, and `SHOW "all"`.
    @Test(arguments: ["SHOW U&\"app\\002ejwt_secret\"", "SHOW U&\"app!002ejwt_secret\" UESCAPE '!'", "SHOW U&\"app\\+00002ejwt_secret\"",
                      "SHOW U&\"app\\002eapi_key\"", "SHOW \"all\"", "SHOW \"ALL\"", "SHOW U&\"\\0061ll\"", "SHOW u&\"\\0061ll\"",
                      "SHOW ALL", "show All", "SHOW \"work_mem\"", "SHOW TIME ZONE", "SHOW TRANSACTION ISOLATION LEVEL", "SHOW SESSION AUTHORIZATION",
                      "SHOW work_mem x", "SHOW work_mem.x", "SHOW app.jwt_secret", "SHOW", "SHOW 'work_mem'", "SHOW wörk_mem", "SHOW ſearch_path",
                      "SHOW work_mem, search_path", "SHOW (work_mem)", "SHOW $1", "SHOW 1"])
    func showTakesOneBuiltInName(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql.debugDescription)")
    }

    // U&-escaped identifiers and UESCAPE can spell any name or keyword: one lexical check refuses them on every statement path
    // (and in literal content), before the statement is classified.
    @Test(arguments: ["SHOW U&\"work_mem\"", "TABLE U&\"t\"", "VALUES (U&\"x\")", "EXPLAIN SELECT U&\"x\" FROM t", "WITH a AS (SELECT 1) SELECT U&\"x\" FROM a",
                      "DELETE FROM U&\"t\"", "SET U&\"work_mem\" = 1", "SELECT U&'x!0041' UESCAPE '!'", "SHOW work_mem UESCAPE '!'",
                      "SELECT zz_exec('SHOW U&\"app\\002ejwt_secret\"')", "SELECT zz_exec('x U&\"t\"')"])
    func unicodeEscapesAreRefusedOnEveryPath(sql: String) {
        let reason = ReadOnlySQLGuard.check(sql) ?? ""
        #expect(reason.contains("Unicode-escaped") || reason.contains("UESCAPE"), "\(sql.debugDescription): \(reason)")
    }

    // Built-in parameters stay readable by name.
    @Test(arguments: ["SHOW work_mem", "SHOW search_path", "show TimeZone", "SHOW transaction_isolation", "SHOW server_version_num", "SHOW work_mem;",
                      "SHOW work_mem -- note", "SHOW /* c */ work_mem", "SHOW POOLS", "SELECT current_setting('work_mem')", "SELECT current_setting('server_version_num')::int",
                      "SELECT pg_catalog.current_setting('search_path', true)", "SELECT current_setting('standard_conforming_strings') AS scs, count(*) FROM t",
                      "SELECT current_setting(E'work_mem'), current_setting($$block_size$$)"])
    func allowsBuiltInSettings(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    // Extensions: functions that run SQL given as text (pgTAP, orafce's dbms_sql, hypopg) or act outside the transaction
    // (orafce's dbms_pipe, dbms_alert, utl_file), and views of other sessions' SQL (pg_stat_monitor, pg_store_plans, …).
    @Test(arguments: ["SELECT lives_ok('x')", "SELECT throws_ok('x', 'P0001')", "SELECT throws_like('x', '%')", "SELECT throws_ilike('x', '%')",
                      "SELECT throws_matching('x', '.')", "SELECT throws_imatching('x', '.')", "SELECT results_eq('a', 'b')", "SELECT results_ne('a', 'b')",
                      "SELECT set_eq('a', 'b')", "SELECT set_ne('a', 'b')", "SELECT set_has('a', 'b')", "SELECT set_hasnt('a', 'b')", "SELECT bag_eq('a', 'b')",
                      "SELECT bag_ne('a', 'b')", "SELECT bag_has('a', 'b')", "SELECT bag_hasnt('a', 'b')", "SELECT is_empty('x')", "SELECT isnt_empty('x')",
                      "SELECT row_eq('x', ROW(1))", "SELECT performs_ok('x', 1)", "SELECT performs_within('x', 1, 1)", "SELECT * FROM runtests()",
                      "SELECT * FROM tap.runtests('s')", "SELECT do_tap()", "SELECT _temptable('x', 'y')", "SELECT _runner(a, b, c, d, e)",
                      "SELECT tap.throws_ok('x')", "SELECT dbms_sql.open_cursor()", "SELECT dbms_sql.parse(1, 'x')", "SELECT \"dbms_sql\".execute(1)",
                      "SELECT DBMS_SQL.EXECUTE(1)", "SELECT dbms_sql . execute(1)", "SELECT utl_file.fopen('/tmp', 'x', 'w')",
                      "SELECT dbms_pipe.send_message('p')", "SELECT dbms_alert.signal('a', 'b')", "SELECT * FROM hypopg_create_index('x')",
                      "SELECT * FROM public.hypopg_create_index('x')", "SELECT query FROM pg_stat_monitor", "SELECT * FROM pg_stat_monitor_internal(true)",
                      "SELECT * FROM pg_store_plans", "SELECT * FROM pg_store_plans_info()", "SELECT * FROM pg_qualstats_all",
                      "SELECT * FROM pg_stat_kcache_detail", "SELECT * FROM pg_show_plans", "SELECT * FROM pg_active_session_history",
                      "SELECT * FROM powa_statements"])
    func refusesKnownExtensionSQLRunnersAndSessionSources(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Extensions that reach the network: pg_net (schema `net`, also through search_path) and pgsql-http.
    @Test(arguments: ["SELECT net.http_get('http://x')", "SELECT net.http_post(url := 'http://x')", "SELECT \"net\".http_delete('http://x')",
                      "SELECT NET.HTTP_GET('http://x')", "SELECT http_get('http://x')", "SELECT http_post('u', 'b', 'c')", "SELECT http_put('u', 'b', 'c')",
                      "SELECT http_patch('u', 'b', 'c')", "SELECT http_delete('u')", "SELECT http_head('u')", "SELECT * FROM http(('GET', 'u', NULL, NULL, NULL))",
                      "SELECT http_request('GET', 'u')", "SELECT http_set_curlopt('CURLOPT_TIMEOUT', '1')", "SELECT http_reset_curlopt()",
                      "SELECT * FROM http_list_curlopt()", "SELECT public.http_get('u')"])
    func refusesNetworkExtensions(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Catalog columns the enumeration finds that are not secret stay readable (schema browsing needs them), as do the
    // ordinary names those rules look like.
    @Test(arguments: ["SELECT relname, reloptions FROM pg_class", "SELECT attname, attoptions, attfdwoptions FROM pg_attribute",
                      "SELECT spcname, spcoptions FROM pg_tablespace", "SELECT relowner::regrole FROM pg_class",
                      "SELECT roleid::regrole, member::regrole FROM pg_auth_members", "SELECT is_empty, dbms_sql FROM t", "SELECT brin FROM t"])
    func allowsHarmlessCatalogColumns(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
    }

    /// The letters whose upper, lower or title case holds an ASCII letter, derived from Unicode properties: the set the guard
    /// refuses in names is exactly these 19 (`İ` lower-cases to `i̇`, `ſ` upper-cases to `S`, `K` is the Kelvin sign).
    @Test func caseUnsafeLettersAreDerivedFromUnicode() {
        func hasASCIILetter(_ text: String) -> Bool { text.unicodeScalars.contains { $0.isASCII && $0.properties.isAlphabetic } }
        var derived: Set<Unicode.Scalar> = []
        for value in UInt32(0x80)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let properties = scalar.properties
            if hasASCIILetter(properties.uppercaseMapping) || hasASCIILetter(properties.lowercaseMapping) || hasASCIILetter(properties.titlecaseMapping) {
                derived.insert(scalar)
            }
        }
        #expect(derived == ReadOnlySQLGuard.caseUnsafeLetters)
        #expect(String(String.UnicodeScalarView(ReadOnlySQLGuard.caseUnsafeLetters.sorted())) == "ßİıŉſǰẖẗẘẙẚKﬀﬁﬂﬃﬄﬅﬆ")
    }

    // In every encoding: a name (identifier, keyword or quoted name) holding one of those letters, which a server folding by
    // locale or by full case mapping can turn into another name. The review's strings resolved to the real names on a
    // Turkish LATIN5 database.
    @Test(arguments: ["SELECT setconfig FROM PG_DB_ROLE_SETTİNG", "SELECT current_settİng('app.jwt_secret')", "SELECT * FROM PG_SETTİNGS",
                      "SELECT query FROM PG_STAT_ACTİVİTY", "SELECT umoptions FROM PG_USER_MAPPİNGS", "SELECT SET_CONFİG('a.b', 'c', false)",
                      "SELECT pg_termİnate_backend(1)", "SELECT pg_advİsory_lock(1)", "SELECT ﬁrst FROM t", "SELECT straße FROM t",
                      "SELECT \"PG_SETTİNGS\".name FROM t", "SELECT 1 FROM ſtats", "SELECT 1 AS \u{212A}elvin", "SELECT ı FROM t",
                      "EXPLAIN SELECT * FROM PG_SETTİNGS", "SELECT zz_exec('SELECT * FROM PG_SETTİNGS')", "SELECT zz_exec('x := pg_termİnate_backend(1)')"])
    func refusesNamesWithCaseUnsafeLetters(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
    }

    // Data and other non-ASCII names stay allowed in a multi-byte database (which never folds non-ASCII letters).
    @Test(arguments: ["SELECT * FROM t WHERE street = 'Hauptstraße'", "SELECT 'İstanbul' AS city, 'ﬁle' AS f", "SELECT café FROM t",
                      "SELECT \"café\", naïve FROM tablé", "SELECT 名前 FROM 表"])
    func allowsDataAndOtherNonASCIINames(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql) == nil, "\(sql)")
        #expect(ReadOnlySQLGuard.check(sql, singleByteEncoding: nil) == nil, "\(sql)")
    }

    // In a single-byte database (LATIN5, WIN1254, SQL_ASCII, …) the server lower-cases high-bit bytes of unquoted names with
    // the locale's tolower(), which the client cannot model: an unquoted name or keyword must be ASCII. Quoted names are
    // exact, and string literals are data.
    @Test(arguments: ["SELECT café FROM t", "SELECT * FROM tablé", "SELECT naïve()", "SELECT 1 AS ñ", "SELECT zz_exec('SELECT café FROM t')",
                      "SELECT zz_exec('x := fünc(1)')", "SELECT * FROM PG_SETTİNGS", "EXPLAIN SELECT café FROM t", "WITH ä AS (SELECT 1) SELECT * FROM ä"])
    func singleByteDatabasesTakeASCIINamesOnly(sql: String) {
        let reason = ReadOnlySQLGuard.check(sql, singleByteEncoding: "LATIN5") ?? ""
        #expect(reason.contains("PG_SETTİNGS") || reason.contains("this database uses a single-byte encoding (LATIN5), where the server folds "
            + "non-ASCII letters in names by locale; quote the name or use ASCII"), "\(sql): \(reason)")
    }

    @Test(arguments: ["SELECT \"café\" FROM \"tablé\"", "SELECT * FROM t WHERE name = 'café'", "SELECT 'Hauptstraße', E'\\u00e9'", "SELECT 1",
                      "SHOW work_mem", "SELECT \"naïve\"(1)"])
    func singleByteDatabasesKeepQuotedNamesAndData(sql: String) {
        #expect(ReadOnlySQLGuard.check(sql, singleByteEncoding: "SQL_ASCII") == nil, "\(sql)")
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
    // Other sessions' SQL, as the MCP tools return it: every string and numeric literal becomes `?` (digest style), and
    // comments go, not only what looks like a credential (a secret in a plain literal is still a secret).
    @Test func digestsReplaceEveryLiteral() {
        #expect(SQLRedactor.digest("SELECT * FROM t WHERE token = 'secret-xyz' AND n = 42 AND x = -1.5e3")
            == "SELECT * FROM t WHERE token = ? AND n = ? AND x = -?")
        #expect(SQLRedactor.digest("SELECT E'a\\'s3cret', $$body s3cret$$, $t$x s3cret$t$, U&'s3cret', B'1010', X'1F', N's3cret', 0x1F, 1_000")
            == "SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?")
        #expect(SQLRedactor.digest("SELECT a /* pw=s3cret */ FROM t -- s3cret\nWHERE b = $1") == "SELECT a FROM t\nWHERE b = $1")
        #expect(SQLRedactor.digest("SELECT \"Mixed\" FROM t WHERE c = 'cut short by track_activity_query_size: s3cret")
            == "SELECT \"Mixed\" FROM t WHERE c = ?")
        // A backslash before a quote: with standard_conforming_strings off the literal runs on, so both readings are redacted.
        #expect(!SQLRedactor.digest("SELECT 'a\\'b s3cret' FROM t").contains("s3cret"))
        #expect(SQLRedactor.digest("SELECT date '2024-01-01', interval '1 day'") == "SELECT date ?, interval ?")
    }

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

