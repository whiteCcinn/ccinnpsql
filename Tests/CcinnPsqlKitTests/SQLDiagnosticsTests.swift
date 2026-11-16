import Foundation
import PostgresKit
import PostgresWire
import Testing
@testable import CcinnPsqlKit

/// Text of a UTF-16 range (what the editor would underline).
private func slice(_ text: String, _ range: Range<Int>?) -> String? {
    guard let range else { return nil }
    let units = Array(text.utf16)
    guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
    return String(decoding: units[range], as: UTF16.self)
}

private func utf16Offset(of needle: String, in text: String) -> Int {
    (text as NSString).range(of: needle).location
}

/// An ErrorResponse with the given fields (`C`, `M`, `P`, `H`, `D`, `W`, `q`, `p`, `s`, `t`, `c`).
private func response(_ fields: [Character: String]) -> SQLServerError {
    var raw: [UInt8: String] = [:]
    for (code, value) in fields {
        if let ascii = code.asciiValue { raw[ascii] = value }
    }
    return SQLServerError(fields: ServerMessageFields(fields: raw))
}

private func marked(_ statement: String, _ fields: [Character: String]) -> String? {
    slice(statement, SQLErrorLocator.range(in: statement, error: response(fields)))
}

// ErrorResponses recorded from PostgreSQL 17 (statement, fields).
private enum Recorded {
    static let formShop: [Character: String] = ["C": "42601", "M": "syntax error at or near \"shop\"", "P": "15"]
    static let nme: [Character: String] = ["C": "42703", "M": "column \"nme\" does not exist", "P": "8",
                                           "H": "Perhaps you meant to reference the column \"t.name\"."]
    static let notNull: [Character: String] = ["C": "23502", "M": "null value in column \"email\" of relation \"customers\" violates not-null constraint",
                                               "D": "Failing row contains (1, null, null, MY, 2026-11-16 17:34:22.905738+00).",
                                               "s": "shop", "t": "customers", "c": "email"]
}

@Suite("Server errors")
struct ServerErrorTests {
    @Test func fieldsAreKept() {
        let error = response(Recorded.nme)
        #expect(error.message == "column \"nme\" does not exist")
        #expect(error.sqlState == "42703")
        #expect(error.position == 8)
        #expect(error.hint == "Perhaps you meant to reference the column \"t.name\".")
        #expect(error.summary == "column \"nme\" does not exist")
        #expect(error.names == [["nme"]])
    }

    @Test func kindAndTitleUseOnlyEditorPositions() {
        let syntax = response(Recorded.formShop)
        #expect(syntax.kindLabel == "Syntax error")
        #expect(syntax.conditionName == "syntax_error")
        #expect(syntax.title(at: nil) == "Syntax error")
        #expect(syntax.title(at: SQLTextPosition(line: 11, column: 4)) == "Syntax error at line 11, column 4")
        #expect(response(Recorded.nme).conditionName == "undefined_column")
        #expect(response(Recorded.notNull).kindLabel == "Integrity violation")
        #expect(response(["C": "22012", "M": "division by zero"]).kindLabel == "Data error")
        #expect(response(["M": "boom"]).kindLabel == "Error")
        #expect(response(["C": "XX999", "M": "x"]).conditionName == nil)
    }

    @Test func diagnosticMessageCarriesHintAndDetail() {
        #expect(response(Recorded.nme).diagnosticMessage
            == "column \"nme\" does not exist — HINT: Perhaps you meant to reference the column \"t.name\".")
        let raised = response(["C": "P0001", "M": "boom 1", "D": "some detail", "H": "try again"])
        #expect(raised.diagnosticMessage == "boom 1 — HINT: try again — DETAIL: some detail")
        #expect(response(Recorded.formShop).diagnosticMessage == "syntax error at or near \"shop\"")
    }

    @Test(arguments: [
        ("column \"nme\" does not exist", [["nme"]]),
        ("column t.nme does not exist", [["t", "nme"]]),
        ("column \"Name\" does not exist", [["Name"]]),
        ("relation \"shop.nosuch_table\" does not exist", [["shop", "nosuch_table"]]),
        ("relation \"Shop.orders\" does not exist", [["Shop", "orders"]]),
        ("relation \"orders\" already exists", [["orders"]]),
        ("table \"nosuch_x\" does not exist", [["nosuch_x"]]),
        ("column \"nosuchcol\" of relation \"orders\" does not exist", [["nosuchcol"], ["orders"]]),
        ("column reference \"id\" is ambiguous", [["id"]]),
        ("function nosuchfn(integer) does not exist", [["nosuchfn"]]),
        ("function shop.f(integer, text) does not exist", [["shop", "f"]]),
        ("schema \"nosuch\" does not exist", [["nosuch"]]),
        ("type \"nosuchtype\" does not exist", [["nosuchtype"]]),
        ("permission denied for table orders", [["orders"]]),
        ("syntax error at or near \"shop\"", []),
        ("unterminated quoted string at or near \"'abc\"", []),
        ("invalid input syntax for type integer: \"x\"", []),
        ("division by zero", []),
    ])
    func namesInMessages(message: String, expected: [[String]]) {
        #expect(response(["M": message]).names == expected)
    }

    @Test func structuredFieldsQualifyNames() {
        // The table from `s`/`t` replaces the unqualified one from the message; the column comes first.
        #expect(response(Recorded.notNull).names == [["email"], ["shop", "customers"]])
        #expect(response(["M": "x", "t": "orders"]).names == [["orders"]])
    }

    @Test func hugeMessagesAreSummarised() {
        let echo = String(repeating: "x ", count: 100_000)
        let error = response(["C": "42601", "M": "unterminated quoted string at or near \"'\(echo)\"", "P": "8",
                              "H": String(repeating: "h", count: 5_000), "D": String(repeating: "d", count: 5_000)])
        #expect(error.summary.count <= SQLServerError.summaryLimit + 1)
        #expect(error.summary.hasSuffix("…"))
        #expect(error.diagnosticMessage.count < 2_000)
        #expect(error.position == 8)
    }

    @Test func displayedFieldsAreBounded() {
        #expect(SQLServerError.shortenedForDisplay("short") == "short")
        let long = SQLServerError.shortenedForDisplay(String(repeating: "x", count: 10_000))
        #expect(long.count == 2_001)
        #expect(long.hasSuffix("…"))
    }

    @Test func errorsWithoutFieldsKeepTheirMessage() {
        let error = SQLServerError(PostgresError(.network, "Connection reset"))
        #expect(error.message == "Connection reset")
        #expect(error.sqlState == nil)
        #expect(error.position == nil)
        let server = SQLServerError(PostgresError(.server, "column \"x\" does not exist",
                                                  fields: ServerMessageFields(fields: [0x43: "42703", 0x4D: "column \"x\" does not exist", 0x50: "8"])))
        #expect(server.position == 8)
        #expect(server.sqlState == "42703")
    }
}

@Suite("Error location")
struct ErrorLocatorTests {
    @Test func positionsCountCodePoints() {
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT x", position: 8) == 7)
        // 𝔸 is one code point but two UTF-16 units.
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT '𝔸', bad", position: 13) == 13)
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT", position: 999) == 6)
        #expect(SQLErrorLocator.utf16Offset(in: "SELECT", position: 0) == nil)
    }

    // Statements and ErrorResponses recorded from PostgreSQL 17.
    @Test(arguments: [
        ("SELECT 1 FORM shop.orders", Recorded.formShop, "shop"),
        ("SELECT '🇲🇾', 1 FORM shop.orders", ["C": "42601", "M": "syntax error at or near \"shop\"", "P": "21"], "shop"),
        ("SELECT nme FROM shop.customers t", Recorded.nme, "nme"),
        ("SELECT t.nme FROM shop.customers t", ["C": "42703", "M": "column t.nme does not exist", "P": "8"], "t.nme"),
        ("SELECT * FROM shop.nosuch_table", ["C": "42P01", "M": "relation \"shop.nosuch_table\" does not exist", "P": "15"], "shop.nosuch_table"),
        ("SELECT * FROM \"Orders\"", ["C": "42P01", "M": "relation \"Orders\" does not exist", "P": "15"], "\"Orders\""),
        ("SELECT * FROM Shop.Nosuch", ["C": "42P01", "M": "relation \"shop.nosuch\" does not exist", "P": "15"], "Shop.Nosuch"),
        ("SELECT * FROM \"Shop\".orders", ["C": "42P01", "M": "relation \"Shop.orders\" does not exist", "P": "15"], "\"Shop\".orders"),
        ("SELECT abs(1,2,3)", ["C": "42883", "M": "function abs(integer, integer, integer) does not exist", "P": "8"], "abs(1,2,3)"),
        ("SELECT nosuchfn(1)", ["C": "42883", "M": "function nosuchfn(integer) does not exist", "P": "8"], "nosuchfn(1)"),
        ("SELECT 1 +", ["C": "42601", "M": "syntax error at end of input", "P": "11"], "+"),
        ("SELECT (1", ["C": "42601", "M": "syntax error at end of input", "P": "10"], "1"),
        ("SELECT * FROM shop.orders WHERE", ["C": "42601", "M": "syntax error at end of input", "P": "32"], "WHERE"),
        ("SELECT 1)", ["C": "42601", "M": "syntax error at or near \")\"", "P": "9"], ")"),
        ("SELECT 'abc", ["C": "42601", "M": "unterminated quoted string at or near \"'abc\"", "P": "8"], "'"),
        ("SELECT \"abc", ["C": "42601", "M": "unterminated quoted identifier at or near \"\"abc\"", "P": "8"], "\""),
        ("SELECT 1 /* x", ["C": "42601", "M": "unterminated /* comment at or near \"/* x\"", "P": "10"], "/*"),
        ("SELECT 1 /* a /* b */", ["C": "42601", "M": "unterminated /* comment at or near \"/* a /* b */\"", "P": "10"], "/*"),
        ("SELECT 1 /* a /* nested */ FORM", ["C": "42601", "M": "unterminated /* comment at or near \"/* a /* nested */ FORM\"", "P": "10"], "/*"),
        ("SELECT $$abc", ["C": "42601", "M": "unterminated dollar-quoted string at or near \"$$abc\"", "P": "8"], "$$"),
        ("SELECT E'a\\'", ["C": "42601", "M": "unterminated quoted string at or near \"E'a\\'\"", "P": "8"], "E'"),
        ("SELECT 1::nosuchtype", ["C": "42704", "M": "type \"nosuchtype\" does not exist", "P": "11"], "nosuchtype"),
        ("SELECT '1'::int + 'x'::int", ["C": "22P02", "M": "invalid input syntax for type integer: \"x\"", "P": "19"], "'x'"),
        ("SELECT id FROM shop.orders o JOIN shop.customers c ON true", ["C": "42702", "M": "column reference \"id\" is ambiguous", "P": "8"], "id"),
        ("UPDATE shop.orders SET nosuchcol = 1", ["C": "42703", "M": "column \"nosuchcol\" of relation \"orders\" does not exist", "P": "24"], "nosuchcol"),
        ("SELECT * FROM shop.orders WHERE status = 1", ["C": "42883", "M": "operator does not exist: shop.order_status = integer", "P": "40"], "="),
        ("SELECT\n  id,\n  nme\nFROM shop.customers", ["C": "42703", "M": "column \"nme\" does not exist", "P": "16"], "nme"),
        ("SELECT \"Name\" FROM shop.customers", ["C": "42703", "M": "column \"Name\" does not exist", "P": "8"], "\"Name\""),
        ("SELECT E'\\x' || nosuch", ["C": "42703", "M": "column \"nosuch\" does not exist", "P": "17"], "nosuch"),
    ] as [(String, [Character: String], String)])
    func positionedErrors(statement: String, fields: [Character: String], expected: String) {
        #expect(marked(statement, fields) == expected)
    }

    // Function bodies: PostgreSQL maps errors in a SQL-language body to the CREATE statement (P inside `$$`).
    @Test func positionsInsideDollarQuotedBodies() {
        let sql = "CREATE OR REPLACE FUNCTION public.zz_c1() RETURNS int LANGUAGE sql AS $$ SELECT nosuch FROM shop.orders $$"
        #expect(marked(sql, ["C": "42703", "M": "column \"nosuch\" does not exist", "P": "81"]) == "nosuch")
        let multiline = "CREATE OR REPLACE FUNCTION public.zz_c2() RETURNS int LANGUAGE sql AS $$\nSELECT 1 FORM t\n$$"
        #expect(marked(multiline, ["C": "42601", "M": "syntax error at or near \"t\"", "P": "88"]) == "t")
        let plpgsql = "CREATE OR REPLACE FUNCTION public.zz_c3() RETURNS int LANGUAGE plpgsql AS $$\nBEGIN\n  RETURN 1 +;\nEND\n$$"
        #expect(marked(plpgsql, ["C": "42601", "M": "syntax error at end of input", "P": "96"]) == ";")
    }

    @Test(arguments: [
        ("DROP TABLE nosuch_x", ["C": "42P01", "M": "table \"nosuch_x\" does not exist"], "nosuch_x"),
        ("CREATE TABLE shop.orders (id int)", ["C": "42P07", "M": "relation \"orders\" already exists"], "orders"),
        ("INSERT INTO shop.customers (id) VALUES (1)", Recorded.notNull, "shop.customers"),
        ("DROP TABLE Nosuch_X", ["C": "42P01", "M": "table \"nosuch_x\" does not exist"], "Nosuch_X"),
    ] as [(String, [Character: String], String)])
    func errorsWithoutAPositionMarkTheNamedObject(statement: String, fields: [Character: String], expected: String) {
        #expect(marked(statement, fields) == expected)
    }

    @Test func namesFollowCaseFolding() {
        // `"Nosuch"` is a different relation from `nosuch`: unquoted names fold to lower case, quoted ones keep it.
        #expect(marked("DROP TABLE \"Nosuch\", nosuch", ["M": "table \"nosuch\" does not exist"]) == "nosuch")
        #expect(marked("DROP TABLE nosuch, \"Nosuch\"", ["M": "table \"Nosuch\" does not exist"]) == "\"Nosuch\"")
        #expect(marked("DROP TABLE NOSUCH", ["M": "table \"Nosuch\" does not exist"]) == nil)
    }

    @Test func namesInsideStringsAndCommentsAreSkipped() {
        let sql = "SELECT 'nosuch', /* nosuch */ nosuch FROM t"
        let range = SQLErrorLocator.range(in: sql, error: response(["M": "column \"nosuch\" does not exist"]))
        #expect(range?.lowerBound == utf16Offset(of: " nosuch FROM", in: sql) + 1)
    }

    // Errors raised inside PL/pgSQL carry the internal query (`q`) and position (`p`) instead of `P`.
    @Test func internalQueriesInDoBlocks() {
        let execute = "DO $$\nBEGIN\n  EXECUTE 'SELECT nosuchcol FROM shop.orders';\nEND\n$$"
        #expect(marked(execute, ["C": "42703", "M": "column \"nosuchcol\" does not exist", "W": "PL/pgSQL function inline_code_block line 3 at EXECUTE",
                                 "q": "SELECT nosuchcol FROM shop.orders", "p": "8"]) == "nosuchcol")
        let insert = "DO $$\nBEGIN\n  INSERT INTO nosuch_ins VALUES (1);\nEND\n$$"
        #expect(marked(insert, ["C": "42P01", "M": "relation \"nosuch_ins\" does not exist", "W": "PL/pgSQL function inline_code_block line 3 at SQL statement",
                                "q": "INSERT INTO nosuch_ins VALUES (1)", "p": "13"]) == "nosuch_ins")
        // PERFORM is rewritten to SELECT, so the query is not in the text: the named relation is found in the body.
        let perform = "DO $$\nBEGIN\n  PERFORM * FROM nosuch_in_do;\nEND\n$$"
        #expect(marked(perform, ["C": "42P01", "M": "relation \"nosuch_in_do\" does not exist", "W": "PL/pgSQL function inline_code_block line 3 at PERFORM",
                                 "q": "SELECT * FROM nosuch_in_do", "p": "15"]) == "nosuch_in_do")
        // A quoted internal query inside a string literal has its quotes doubled.
        let quoted = "DO $$ BEGIN EXECUTE 'SELECT ''a'' || nosuch'; END $$"
        #expect(marked(quoted, ["M": "column \"nosuch\" does not exist", "q": "SELECT 'a' || nosuch", "p": "15"]) == "nosuch")
    }

    @Test func contextLinesLocateRuntimeErrors() {
        let assignment = "DO $$\nDECLARE x int;\nBEGIN\n  x := 1/0;\nEND\n$$"
        #expect(marked(assignment, ["C": "22012", "M": "division by zero",
                                    "W": "PL/pgSQL assignment \"x := 1/0\"\nPL/pgSQL function inline_code_block line 4 at assignment"]) == "x := 1/0")
        let raise = "DO $do$\nBEGIN\n  RAISE EXCEPTION 'boom %', 1 USING HINT = 'try again';\nEND\n$do$"
        #expect(marked(raise, ["C": "P0001", "M": "boom 1", "W": "PL/pgSQL function inline_code_block line 3 at RAISE"])
            == "RAISE EXCEPTION 'boom %', 1 USING HINT = 'try again';")
        // A function defined elsewhere: nothing in the editor is marked.
        #expect(marked("SELECT zz_plpgsql()", ["C": "42P01", "M": "relation \"nosuch_in_fn\" does not exist",
                                               "W": "PL/pgSQL function zz_plpgsql() line 1 at PERFORM",
                                               "q": "SELECT * FROM nosuch_in_fn", "p": "15"]) == nil)
        #expect(marked("SELECT 1/0", ["C": "22012", "M": "division by zero"]) == nil)
        #expect(marked("DO $$ BEGIN PERFORM 1; END $$", ["M": "boom", "W": "PL/pgSQL function inline_code_block line 9 at RAISE"]) == nil)
    }

    // A simple-protocol script: `P` counts from the start of the whole script.
    @Test func scriptPositionsAreRelativeToTheScript() {
        let script = "SELECT 1; SELECT nosuch FROM shop.orders; SELECT 2"
        #expect(marked(script, ["C": "42703", "M": "column \"nosuch\" does not exist", "P": "18"]) == "nosuch")
        let lines = "SELECT 1;\nSELECT 2 FORM t"
        #expect(marked(lines, ["C": "42601", "M": "syntax error at or near \"t\"", "P": "25"]) == "t")
    }

    // Without a position, only the statement that failed (after `completedStatements` completed ones) is searched:
    // the alias `nosuch_x` in the first statement must not be marked for the DROP's error.
    @Test func scriptErrorsWithoutAPositionSearchTheFailingStatement() throws {
        let script = "SELECT 'x' AS nosuch_x; DROP TABLE nosuch_x; SELECT 2"
        let dropped = response(["C": "42P01", "M": "table \"nosuch_x\" does not exist"])
        let found = try #require(SQLErrorLocator.scriptRange(in: script, error: dropped, completedStatements: 1))
        #expect(found.range.lowerBound == utf16Offset(of: "nosuch_x; SELECT 2", in: script))
        #expect(slice(script, found.statement) == "DROP TABLE nosuch_x")
        #expect(SQLErrorLocator.scriptRange(in: script, error: dropped, completedStatements: 5) == nil)
        #expect(SQLErrorLocator.scriptRange(in: script, error: dropped, completedStatements: nil) == nil)
        // With a position the whole script is the reference; the statement is the one containing the mark.
        let positioned = try #require(SQLErrorLocator.scriptRange(in: "SELECT 1; SELECT nosuch FROM shop.orders; SELECT 2",
                                                                  error: response(["C": "42703", "M": "column \"nosuch\" does not exist", "P": "18"]),
                                                                  completedStatements: 1))
        #expect(positioned.range == 17..<23)
        #expect(positioned.statement == 10..<40)
    }

    @Test func explainPrefixMapsBack() {
        let source = "SELECT 1 FORM shop.orders"
        let prefix = "EXPLAIN (FORMAT JSON) "
        let mapping = SQLExecutedTextMapping(prefixLength: prefix.utf16.count)
        let error = response(["C": "42601", "M": "syntax error at or near \"shop\"", "P": "37"])
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: prefix + source, mapping: mapping, error: error)) == "shop")
    }

    @Test func autoLimitInsertionMapsBack() {
        let source = "SELECT * FROM shop.orders WHERE -- todo"
        let outcome = AutoLimit.apply(to: source, limit: 1000)
        #expect(outcome.applied)
        let at = utf16Offset(of: " -- todo", in: source)
        #expect(outcome.insertion == at..<(at + " LIMIT 1000".utf16.count))
        let mapping = SQLExecutedTextMapping(insertion: outcome.insertion)
        // PostgreSQL stops at the inserted LIMIT; it maps to the insertion point (the last source token).
        let error = response(["C": "42601", "M": "syntax error at or near \"LIMIT\"", "P": "33"])
        #expect(slice(source, SQLErrorLocator.range(in: source, executed: outcome.sql, mapping: mapping, error: error)) == "WHERE")
        #expect(mapping.sourceOffset(forExecuted: outcome.sql.utf16.count) == source.utf16.count)
        #expect(AutoLimit.apply(to: "SELECT 1 LIMIT 3", limit: 10).insertion == nil)
    }

    @Test func emptyAndUnlocatableInput() {
        #expect(SQLErrorLocator.range(in: "", error: response(["M": "x", "P": "1"])) == nil)
        #expect(SQLErrorLocator.range(in: "SELECT 1", error: response(["M": "column \"zzz\" does not exist"])) == nil)
        #expect(SQLErrorLocator.range(in: "   ", error: response(["M": "syntax error at end of input", "P": "4"])) == nil)
    }
}

@Suite("Error location bounds")
struct ErrorLocatorBoundsTests {
    @Test func hugePositionsAreClamped() {
        let statement = "SELECT\nabc"
        #expect(slice(statement, SQLErrorLocator.range(in: statement, error: response(["M": "x", "P": "2147483647"]))) == "abc")
        #expect(SQLErrorLocator.range(in: statement, error: response(["M": "x", "P": "99999999999999999999"])) == nil)
        #expect(SQLErrorLocator.range(in: statement, error: response(["M": "x", "q": "abc", "p": "2147483647"])) != nil)
    }

    @Test func mappingNeverGoesNegative() {
        let mapping = SQLExecutedTextMapping(prefixLength: 8, insertion: 20..<29)
        #expect(mapping.sourceOffset(forExecuted: 0) == 0)
        #expect(mapping.sourceOffset(forExecuted: Int.max) == Int.max - 9 - 8)
        #expect(mapping.sourceOffset(forExecuted: 25) == 12)
    }
}

@Suite("Local checks")
struct LinterTests {
    private func lint(_ text: String) -> [(SQLDiagnostic.Severity, String, String)] {
        SQLLinter.diagnose(text).map { ($0.severity, slice(text, $0.range) ?? "?", $0.message) }
    }

    @Test func unclosedParenthesis() {
        let found = lint("SELECT count(1 FROM t")
        #expect(found.count == 1)
        #expect(found.first?.0 == .error)
        #expect(found.first?.1 == "(")
        #expect(found.first?.2 == "'(' is not closed")
    }

    @Test func unmatchedClosers() {
        #expect(lint("SELECT 1)").map(\.1) == [")"])
        #expect(lint("SELECT 1)").first?.2 == "Unmatched ')': there is no matching '(' before it")
        #expect(lint("SELECT arr[1 FROM t").map { [$0.1, $0.2] } == [["[", "'[' is not closed"]])
        #expect(lint("SELECT 1]").map(\.2) == ["Unmatched ']': there is no matching '[' before it"])
    }

    // Statements end where the splitter ends them: never at a `;` inside parentheses (CREATE RULE … DO (a; b)).
    @Test func parenthesesFollowTheSplitter() {
        let text = "SELECT 1); SELECT (2"
        let diagnostics = SQLLinter.diagnose(text)
        #expect(diagnostics.map { slice(text, $0.range) } == [")", "("])
        #expect(diagnostics.first?.scope == 0..<9)
        #expect(diagnostics.last?.scope == 18..<20)
        let unclosed = SQLLinter.diagnose("SELECT (1; SELECT 2")
        #expect(unclosed.map(\.range) == [7..<8])
        #expect(unclosed.first?.scope == 7..<19)
    }

    @Test func unterminatedQuotes() {
        #expect(lint("SELECT 'abc").map { [$0.1, $0.2] } == [["'", "Unterminated string: add the closing '"]])
        #expect(lint("SELECT \"abc").map { [$0.1, $0.2] } == [["\"", "Unterminated quoted identifier: add the closing \""]])
        #expect(lint("SELECT E'a\\'").map(\.1) == ["E'"])
        #expect(lint("SELECT U&'a").map(\.1) == ["U&'"])
        #expect(lint("SELECT U&\"a").map(\.1) == ["U&\""])
        #expect(lint("SELECT $$abc").map { [$0.1, $0.2] } == [["$$", "Unterminated dollar-quoted string: add the closing $$"]])
        #expect(lint("SELECT $fn$ abc $other$").map { [$0.1, $0.2] } == [["$fn$", "Unterminated dollar-quoted string: add the closing $fn$"]])
    }

    @Test func unterminatedQuoteSuppressesParenthesisNoise() {
        #expect(lint("SELECT count('abc)").map(\.1) == ["'"])
        #expect(lint("SELECT count($$abc)").map(\.1) == ["$$"])
    }

    // PostgreSQL nests block comments: `/* a /* b */` is still open.
    @Test func unterminatedBlockComments() {
        #expect(lint("SELECT 1 /* note").map { [$0.1, $0.2] } == [["/*", "Unterminated comment: add the closing */"]])
        #expect(lint("SELECT 1 /* a /* b */").map { [$0.1, $0.2] } == [["/*", "Unterminated comment: add the closing */"]])
        #expect(lint("SELECT 1 /* a /* b").map(\.2) == ["Unterminated comment: add 2 closing */ (block comments nest)"])
        #expect(lint("SELECT 1 /*/").map(\.1) == ["/*"])
    }

    @Test(arguments: [
        "SELECT 'it''s', \"a\"\"b\", (1), E'\\'' FROM t",
        "SELECT 1 -- (",
        "/* /* nested */ */ SELECT (1)",
        "SELECT ')' FROM t",
        "",
        "SELECT $$ ( $$, $t$ ) $t$",
        "SELECT x::numeric(10,2), arr[1], ARRAY[(1)], '(1'::text, 1::int[]",
        "SELECT $1 + $2",
        "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))",
        "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT (1); SELECT 2; END",
        "DO $$ BEGIN RAISE NOTICE '(' ; END $$",
    ])
    func cleanTextHasNoDiagnostics(text: String) {
        #expect(SQLLinter.diagnose(text).isEmpty)
    }

    @Test func diagnosticsAreCapped() {
        #expect(SQLLinter.diagnose(String(repeating: ")", count: 500)).count == SQLLinter.maximumDiagnostics)
    }

    @Test func localDiagnosticsAreMarkedAsLocal() {
        #expect(SQLLinter.diagnose("SELECT (").allSatisfy { $0.source == .local })
    }
}

@Suite("Diagnostic edit tracking")
struct DiagnosticTrackingTests {
    private let diagnostic = SQLDiagnostic(range: 10..<14, scope: 5..<20, severity: .error, source: .server, message: "m")

    private func apply(_ edits: SQLTextEdit...) -> SQLDiagnostic? {
        SQLDiagnosticTracker.apply(edits, to: [diagnostic]).first
    }

    @Test func editBeforeShifts() {
        let moved = apply(SQLTextEdit(range: 0..<0, replacementLength: 3))
        #expect(moved?.range == 13..<17)
        #expect(moved?.scope == 8..<23)
    }

    @Test func separatedInsertionAtScopeStartShifts() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 2, separatorBeforeEnd: true))?.range == 12..<16)
    }

    @Test func gluedInsertionAtScopeStartDrops() {
        #expect(apply(SQLTextEdit(range: 5..<5, replacementLength: 1, separatorBeforeEnd: false)) == nil)
    }

    @Test func deletionEndingAtScopeStart() {
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: true))?.scope == 2..<17)
        #expect(apply(SQLTextEdit(range: 2..<5, replacementLength: 0, separatorBeforeEnd: false)) == nil)
    }

    @Test func separatedInsertionAtScopeEndKeeps() {
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: true)) == diagnostic)
        #expect(apply(SQLTextEdit(range: 20..<20, replacementLength: 1, separatorAtStart: false)) == nil)
    }

    @Test func editAfterKeeps() {
        #expect(apply(SQLTextEdit(range: 21..<21, replacementLength: 1)) == diagnostic)
    }

    @Test(arguments: [SQLTextEdit(range: 12..<12, replacementLength: 1), SQLTextEdit(range: 20..<20, replacementLength: 1),
                      SQLTextEdit(range: 3..<6, replacementLength: 1), SQLTextEdit(range: 19..<25, replacementLength: 0),
                      SQLTextEdit(range: 0..<100, replacementLength: 0), SQLTextEdit(range: 6..<6, replacementLength: 1, separatorBeforeEnd: true)])
    func editTouchingTheScopeDrops(edit: SQLTextEdit) {
        #expect(SQLDiagnosticTracker.apply([edit], to: [diagnostic]).isEmpty)
    }

    @Test func sequencesApplyInOrder() {
        #expect(apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 0..<3, replacementLength: 0)) == diagnostic)
        #expect(apply(SQLTextEdit(range: 0..<0, replacementLength: 3), SQLTextEdit(range: 14..<14, replacementLength: 1)) == nil)
    }

    @Test func rangeEditTracksASingleRange() {
        #expect(SQLTextEdit(range: 0..<0, replacementLength: 4).adjust(6..<9) == 10..<13)
        #expect(SQLTextEdit(range: 7..<7, replacementLength: 4).adjust(6..<9) == nil)
    }

    @Test func malformedEditsDrop() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<0, replacementLength: -5)], to: [diagnostic]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [diagnostic]).isEmpty)
    }

    // The edit is described from the text after it, as NSTextStorage reports it.
    @Test func editsDescribedFromTheEditedText() throws {
        let glued = try #require(SQLTextEdit.made(in: "SELECT 1;xSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(!glued.separatorBeforeEnd)
        #expect(glued.adjust(9..<24) == nil)
        let newline = try #require(SQLTextEdit.made(in: "SELECT 1;\nSELECT x FORM t", editedRange: NSRange(location: 9, length: 1), changeInLength: 1))
        #expect(newline.adjust(9..<24) == 10..<25)
        let after = try #require(SQLTextEdit.made(in: "SELECT x FORM t\n", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(after.separatorAtStart)
        #expect(after.adjust(0..<15) == 0..<15)
        #expect(after.insertedLineBreaks == [0])
        let typed = try #require(SQLTextEdit.made(in: "SELECT x FORM tx", editedRange: NSRange(location: 15, length: 1), changeInLength: 1))
        #expect(typed.adjust(0..<15) == nil)
        let merged = try #require(SQLTextEdit.made(in: "SELECT 1SELECT x", editedRange: NSRange(location: 8, length: 0), changeInLength: -1))
        #expect(merged.range == 8..<9)
        #expect(merged.adjust(9..<16) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 2, length: 5), changeInLength: 0) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: 1, length: 1), changeInLength: 3) == nil)
        #expect(SQLTextEdit.made(in: "abc", editedRange: NSRange(location: NSNotFound, length: 0), changeInLength: 0) == nil)
    }

    // A surrogate pair typed or deleted is two UTF-16 units, as NSRange counts them.
    @Test func surrogatePairsShiftByTheirUnits() throws {
        let edit = try #require(SQLTextEdit.made(in: "🇲🇾 SELECT x", editedRange: NSRange(location: 0, length: 5), changeInLength: 5))
        #expect(edit.adjust(0..<10) == 5..<15)
    }
}

@Suite("Local diagnostic tracking")
struct LocalTrackingTests {
    private let local = SQLDiagnostic(range: 12..<13, scope: 12..<20, severity: .error, source: .local, message: "'(' is not closed")

    @Test func typingInsideTheScopeKeepsTheMarker() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 15..<15, replacementLength: 1)], to: [local]).first
        #expect(moved?.range == 12..<13)
        #expect(moved?.scope == 12..<21)
    }

    @Test func typingRightAfterTheMarkKeepsIt() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 13..<13, replacementLength: 2)], to: [local]).first?.range == 12..<13)
    }

    @Test func insertionBeforeTheMarkShiftsIt() {
        let moved = SQLDiagnosticTracker.apply([SQLTextEdit(range: 12..<12, replacementLength: 2)], to: [local]).first
        #expect(moved?.range == 14..<15)
        #expect(moved?.scope == 14..<22)
    }

    @Test func editingTheMarkedTextDrops() {
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 11..<13, replacementLength: 0)], to: [local]).isEmpty)
        #expect(SQLDiagnosticTracker.apply([SQLTextEdit(range: 0..<Int.max, replacementLength: 0)], to: [local]).isEmpty)
    }
}

@Suite("Diagnostic navigation")
struct NavigationTests {
    @Test func adjacentDiagnosticsAreReachable() {
        let diagnostics = SQLLinter.diagnose("SELECT count((a FROM t")
        #expect(diagnostics.map(\.range) == [12..<13, 13..<14])
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 12) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: 13) == 1)
    }

    @Test func preferenceResolvesTies() {
        let a = SQLDiagnostic(range: 5..<9, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 5..<6, scope: 5..<20, severity: .error, source: .local, message: "b")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b], cursor: 5, preferred: b) == 1)
    }

    @Test func cursorPositions() {
        let a = SQLDiagnostic(range: 2..<10, scope: 0..<20, severity: .error, source: .server, message: "a")
        let b = SQLDiagnostic(range: 4..<5, scope: 4..<20, severity: .error, source: .local, message: "b")
        let c = SQLDiagnostic(range: 14..<15, scope: 14..<20, severity: .error, source: .local, message: "c")
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 4) == 1)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 7) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 15) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 12) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 0) == 0)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [a, b, c], cursor: 99) == 2)
        #expect(SQLDiagnosticNavigator.currentIndex(in: [], cursor: 0) == nil)
    }
}

@Suite("Line index")
struct LineIndexTests {
    @Test func positionsAreOneBasedCodePoints() {
        let text = "SELECT\n  '🇲🇾' x"
        let index = SQLLineIndex(text)
        #expect(index.lineStarts == [0, 7])
        #expect(index.position(of: utf16Offset(of: "x", in: text), in: text as NSString) == SQLTextPosition(line: 2, column: 8))
        #expect(index.position(of: 999, in: text as NSString) == SQLTextPosition(line: 2, column: 9))
        #expect(index.position(of: -1, in: text as NSString) == SQLTextPosition(line: 1, column: 1))
    }

    @Test func editsKeepTheIndexEqualToARebuild() throws {
        var generator = SystemRandomNumberGenerator()
        let alphabet = Array("ab\n;吉🇲🇾 ")
        var text = "SELECT 1;\nSELECT 2\n"
        var index = SQLLineIndex(text)
        for _ in 0..<1_500 {
            let units = Array(text.utf16)
            let start = Int.random(in: 0...units.count, using: &generator)
            let end = Int.random(in: start...min(units.count, start + 6), using: &generator)
            let inserted = String((0..<Int.random(in: 0...4, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
            let updated = String(decoding: units[..<start], as: UTF16.self) + inserted + String(decoding: units[end...], as: UTF16.self)
            let insertedLength = updated.utf16.count - (units.count - (end - start))
            let edit = try #require(SQLTextEdit.made(in: updated as NSString, editedRange: NSRange(location: start, length: insertedLength),
                                                     changeInLength: insertedLength - (end - start)))
            let applied = index.apply(edit)
            #expect(applied)
            text = updated
            #expect(index == SQLLineIndex(text))
        }
    }

    @Test func invalidEditsAreRefused() {
        var index = SQLLineIndex("ab\ncd")
        let beyondEnd = index.apply(SQLTextEdit(range: 3..<9, replacementLength: 0))
        let negative = index.apply(SQLTextEdit(range: 0..<0, replacementLength: -1))
        #expect(!beyondEnd)
        #expect(!negative)
        #expect(index == SQLLineIndex("ab\ncd"))
    }
}

@Suite("Text positions")
struct TextPositionTests {
    @Test func lineAndColumnAreOneBasedCodePoints() {
        let text = "SELECT\n  o.x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "o.x", in: text), in: text) == SQLTextPosition(line: 2, column: 3))
        let emoji = "'🇲🇾' x"
        #expect(SQLTextPosition.lineAndColumn(of: utf16Offset(of: "x", in: emoji), in: emoji) == SQLTextPosition(line: 1, column: 6))
        #expect(SQLTextPosition.lineAndColumn(of: 999, in: "ab\nc") == SQLTextPosition(line: 2, column: 2))
        #expect(SQLTextPosition.lineAndColumn(of: -3, in: "ab") == SQLTextPosition(line: 1, column: 1))
    }
}

@Suite("Diagnostics robustness")
struct DiagnosticsFuzzTests {
    @Test func randomInputNeverCrashes() {
        let alphabet = Array("select from do 'x' E'\\'' \"y\" $$ $t$ -- /* */ ; . , ( ) [ ] :: $1 1e9 吉 🇲🇾 \\ \n")
        let errors: [SQLServerError] = [
            response(["M": "x", "P": "3"]), response(["M": "x", "P": "999"]),
            response(["M": "column t.x does not exist"]), response(["M": "relation \"a.b\" does not exist"]),
            response(["M": "function f(integer) does not exist", "P": "1"]),
            response(["M": "x", "q": "select from", "p": "8"]),
            response(["M": "x", "W": "PL/pgSQL function inline_code_block line 2 at RAISE"]),
            response(["M": "x", "W": "SQL statement \"select\"\nPL/pgSQL function inline_code_block line 1 at PERFORM"]),
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String((0..<Int.random(in: 0...80, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
            let length = text.utf16.count
            let diagnostics = SQLLinter.diagnose(text)
            for diagnostic in diagnostics {
                #expect(diagnostic.range.lowerBound >= 0 && diagnostic.range.upperBound <= length && !diagnostic.range.isEmpty)
                #expect(diagnostic.scope.lowerBound <= diagnostic.range.lowerBound && diagnostic.range.upperBound <= diagnostic.scope.upperBound)
            }
            for error in errors {
                if let range = SQLErrorLocator.range(in: text, error: error) {
                    #expect(range.lowerBound >= 0 && range.upperBound <= length && !range.isEmpty)
                }
            }
            let start = Int.random(in: 0...length, using: &generator)
            let end = Int.random(in: start...length, using: &generator)
            let edit = SQLTextEdit(range: start..<end, replacementLength: Int.random(in: 0...5, using: &generator),
                                   separatorBeforeEnd: Bool.random(using: &generator), separatorAtStart: Bool.random(using: &generator))
            for diagnostic in SQLDiagnosticTracker.apply([edit], to: diagnostics) {
                #expect(diagnostic.range.lowerBound >= 0)
            }
            _ = SQLTextPosition.lineAndColumn(of: Int.random(in: -2...(length + 2), using: &generator), in: text)
        }
    }
}
