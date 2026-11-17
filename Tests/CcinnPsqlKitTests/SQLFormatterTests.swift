import Foundation
import Testing
@testable import CcinnPsqlKit

@Suite("SQL formatter")
struct SQLFormatterTests {
    private func format(_ sql: String, _ options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        SQLFormatter.format(sql, options: options)
    }

    @Test func selectListsBreakOneItemPerLine() {
        #expect(format("select a, b from t where x = 1 and y = 2 order by a") == """
            SELECT
              a,
              b
            FROM t
            WHERE x = 1
              AND y = 2
            ORDER BY a
            """)
    }

    @Test func aSingleItemStaysOnTheClauseLine() {
        #expect(format("select count(*) from t limit 10 offset 5") == "SELECT count(*)\nFROM t\nLIMIT 10\nOFFSET 5")
        #expect(format("SELECT DISTINCT a, b FROM t") == "SELECT DISTINCT\n  a,\n  b\nFROM t")
        #expect(format("select distinct on (a) a, b from t") == "SELECT DISTINCT ON (a)\n  a,\n  b\nFROM t")
        #expect(format("select a from t fetch first 5 rows only") == "SELECT a\nFROM t\nFETCH FIRST 5 ROWS ONLY")
    }

    @Test func joinsAndTheirConditions() {
        #expect(format("select o.id, c.name from orders o left join customers c on o.cid = c.id and c.x > 0 where o.total>10") == """
            SELECT
              o.id,
              c.name
            FROM orders o
            LEFT JOIN customers c
              ON o.cid = c.id
              AND c.x > 0
            WHERE o.total > 10
            """)
        #expect(format("select * from a cross join b inner join c using (id) natural left join d full outer join e on true")
            == "SELECT *\nFROM a\nCROSS JOIN b\nINNER JOIN c USING (id)\nNATURAL LEFT JOIN d\nFULL OUTER JOIN e\n  ON TRUE")
        #expect(format("select * from a left join lateral (select b from c where c.a = a.id) x on true") == """
            SELECT *
            FROM a
            LEFT JOIN LATERAL (
              SELECT b
              FROM c
              WHERE c.a = a.id
            ) x
              ON TRUE
            """)
    }

    @Test func subqueriesAreIndented() {
        #expect(format("select * from (select a from t) s where a in (select a from u where b = 1) and exists (select 1 from v)") == """
            SELECT *
            FROM (
              SELECT a
              FROM t
            ) s
            WHERE a IN (
              SELECT a
              FROM u
              WHERE b = 1
            )
              AND EXISTS (
                SELECT 1
                FROM v
              )
            """)
    }

    @Test func commonTableExpressions() {
        #expect(format("with recursive x as (select 1 as a), y as materialized (select 2 as b) select * from x, y") == """
            WITH RECURSIVE x AS (
              SELECT 1 AS a
            ),
            y AS MATERIALIZED (
              SELECT 2 AS b
            )
            SELECT *
            FROM x, y
            """)
    }

    @Test func betweenKeepsItsAnd() {
        #expect(format("select a from t where d between 1 and 5 and b = 2 or c is not null") == """
            SELECT a
            FROM t
            WHERE d BETWEEN 1 AND 5
              AND b = 2
              OR c IS NOT NULL
            """)
        #expect(format("select a from t where d not between symmetric 1 and 5 and b") == "SELECT a\nFROM t\nWHERE d NOT BETWEEN SYMMETRIC 1 AND 5\n  AND b")
    }

    @Test func conditionsInsideParenthesesStayInline() {
        #expect(format("select a from t where (a = 1 or b = 2) and c = 3") == "SELECT a\nFROM t\nWHERE (a = 1 OR b = 2)\n  AND c = 3")
    }

    @Test func caseExpressionsWithSeveralBranches() {
        #expect(format("select case when a then 1 when b then 2 else 3 end as x, y from t") == """
            SELECT
              CASE
                WHEN a THEN 1
                WHEN b THEN 2
                ELSE 3
              END AS x,
              y
            FROM t
            """)
        #expect(format("select case when a then 1 end from t") == "SELECT CASE WHEN a THEN 1 END\nFROM t")
    }

    @Test func groupByHavingAndWindows() {
        #expect(format("select city, sum(total) over (partition by city order by d) s, count(*) filter (where x) from t group by city, d having sum(total) > 10") == """
            SELECT
              city,
              sum(total) OVER (PARTITION BY city ORDER BY d) s,
              count(*) FILTER (WHERE x)
            FROM t
            GROUP BY
              city,
              d
            HAVING sum(total) > 10
            """)
        #expect(format("select percentile_cont(0.5) within group (order by x) from t group by rollup (a, b)")
            == "SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY x)\nFROM t\nGROUP BY ROLLUP (a, b)")
    }

    @Test func insertUpdateAndDelete() {
        #expect(format("insert into t (a, b) values (1, 'x'), (2, 'y')") == "INSERT INTO t (a, b)\nVALUES\n  (1, 'x'),\n  (2, 'y')")
        #expect(format("insert into t select a from u") == "INSERT INTO t\nSELECT a\nFROM u")
        #expect(format("update t set a = 1, b = 2 from u where t.id = u.id returning t.id, t.a") == """
            UPDATE t
            SET
              a = 1,
              b = 2
            FROM u
            WHERE t.id = u.id
            RETURNING
              t.id,
              t.a
            """)
        #expect(format("delete from t where id = 3 returning *") == "DELETE FROM t\nWHERE id = 3\nRETURNING *")
        #expect(format("insert into t (id, a) values (1, 2) on conflict (id) do update set a = excluded.a")
            == "INSERT INTO t (id, a)\nVALUES (1, 2)\nON CONFLICT (id) DO UPDATE SET a = excluded.a")
        #expect(format("insert into t (id) values (1) on conflict do nothing") == "INSERT INTO t (id)\nVALUES (1)\nON CONFLICT DO NOTHING")
    }

    @Test func tableDefinitions() {
        let sql = "create table if not exists shop.t (id bigint not null, name varchar(32), total numeric(12, 2) default 0, "
            + "primary key (id), foreign key (cid) references shop.c (id)) partition by range (id)"
        #expect(format(sql) == """
            CREATE TABLE IF NOT EXISTS shop.t (
              id bigint NOT NULL,
              name varchar(32),
              total numeric(12, 2) DEFAULT 0,
              PRIMARY KEY (id),
              FOREIGN KEY (cid) REFERENCES shop.c (id)
            )
            PARTITION BY RANGE (id)
            """)
        // Partitions and storage parameters are not queries: FROM / TO / WITH stay inline.
        #expect(format("create table p1 partition of t for values from (1) to (10) with (fillfactor = 70)")
            == "CREATE TABLE p1 PARTITION OF t FOR VALUES FROM (1) TO (10) WITH (fillfactor = 70)")
        #expect(format("create or replace view v as select a, b from t") == "CREATE OR REPLACE VIEW v AS\nSELECT\n  a,\n  b\nFROM t")
    }

    @Test func lockingTriggersAndDataModifyingCTEs() {
        #expect(format("select 1 from t for no key update of t skip locked") == "SELECT 1\nFROM t\nFOR NO KEY UPDATE OF t SKIP LOCKED")
        #expect(format("create trigger trg before insert or update of a on t for each row execute function f()")
            == "CREATE TRIGGER trg BEFORE INSERT OR UPDATE OF a ON t FOR EACH ROW EXECUTE FUNCTION f()")
        #expect(format("with u as (update t set x = 1 returning *) select * from u")
            == "WITH u AS (UPDATE t SET x = 1 RETURNING *)\nSELECT *\nFROM u")
        #expect(format("with u as (insert into t values (1) on conflict (id) do update set a = 2 returning *) delete from v where id = 1")
            == "WITH u AS (INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 2 RETURNING *)\nDELETE FROM v\nWHERE id = 1")
        #expect(format("create function f() returns int language sql begin atomic select 1; select 2; end")
            == "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC\nSELECT 1;\nSELECT 2;\nEND")
    }

    // Function bodies are strings: never touched.
    @Test func functionBodiesAreUntouched() {
        #expect(format("create function f(a int) returns int language sql as $$ select   a  +1 $$")
            == "CREATE FUNCTION f(a int) RETURNS int LANGUAGE sql AS $$ select   a  +1 $$")
        #expect(format("do $do$ begin raise notice 'x'; end $do$") == "DO $do$ begin raise notice 'x'; end $do$")
    }

    // `;` inside parentheses (CREATE RULE) or a BEGIN ATOMIC body does not end the statement.
    @Test func semicolonsInsideBodies() {
        #expect(format("create rule r as on insert to t do also (insert into a values (1); insert into b values (2))")
            == "CREATE RULE r AS ON INSERT TO t DO ALSO (INSERT INTO a VALUES (1); INSERT INTO b VALUES (2))")
    }

    @Test func stringsQuotedNamesAndCommentsAreUntouched() {
        #expect(format("select 'a  b', \"x  y\", E'c\\n  d', $q$ e  f $q$ -- keep\nfrom t /* c  d */ where a=1") == """
            SELECT
              'a  b',
              "x  y",
              E'c\\n  d',
              $q$ e  f $q$ -- keep
            FROM t /* c  d */
            WHERE a = 1
            """)
        #expect(format("-- header\n\nselect /* note */ a, b from t") == """
            -- header
            SELECT /* note */
              a,
              b
            FROM t
            """)
    }

    // Adjacent string literals concatenate only across a newline (`'a'` newline `'b'` is 'ab'; on one line it is an error).
    @Test func stringContinuationsKeepTheirNewline() throws {
        let continued = try #require(format("select 'a'\n'b' as s from t"))
        #expect(continued == "SELECT 'a'\n  'b' AS s\nFROM t")
        #expect(format("select 'a' 'b'") == "SELECT 'a' 'b'", "an error stays the same error")
        #expect(format("select 'a' -- c\n'b'") == "SELECT 'a' -- c\n  'b'")
    }

    @Test func statementsAreSeparatedByABlankLine() {
        #expect(format("select 1;select 2;\n\n\nshow search_path") == "SELECT 1;\n\nSELECT 2;\n\nSHOW search_path")
        #expect(format("select 1; -- done\nselect 2") == "SELECT 1; -- done\n\nSELECT 2")
        #expect(format("select 1;\n") == "SELECT 1;\n", "a trailing newline is kept")
        #expect(format("begin; set search_path to app, public; commit") == "BEGIN;\n\nSET search_path TO app, public;\n\nCOMMIT")
    }

    @Test func operatorsCastsAndPunctuation() {
        #expect(format("select a+b*-1, t.*, arr[1], -x, $1, a<>b, c>=-2, x::int, (a+b)::numeric(10,2), arr[1:2], data->>'k', ARRAY[1,2] from t") == """
            SELECT
              a + b * -1,
              t.*,
              arr[1],
              -x,
              $1,
              a <> b,
              c >= -2,
              x::int,
              (a + b)::numeric(10, 2),
              arr[1:2],
              data ->> 'k',
              ARRAY[1, 2]
            FROM t
            """)
        // `date` is a type name, not a PostgreSQL keyword; INTERVAL is a keyword before its literal.
        #expect(format("select cast(a as int), coalesce(b, 1), f(x => 1), date '2024-01-01', interval '1 day' from t") == """
            SELECT
              CAST(a AS int),
              coalesce(b, 1),
              f(x => 1),
              date '2024-01-01',
              INTERVAL '1 day'
            FROM t
            """)
        #expect(format("select x::text[] from t where y = any (array[1])") == "SELECT x::text[]\nFROM t\nWHERE y = ANY (ARRAY[1])")
        #expect(format("select j->'a', j#>'{a,b}', j #>> '{a}', j@>'{}', U&'d\\0061t', u&\"x\" from t")
            == "SELECT\n  j -> 'a',\n  j #> '{a,b}',\n  j #>> '{a}',\n  j @> '{}',\n  U&'d\\0061t',\n  u&\"x\"\nFROM t")
        #expect(format("select sum(a) over w from t window w as (partition by b order by c)")
            == "SELECT sum(a) OVER w\nFROM t\nWINDOW w AS (PARTITION BY b ORDER BY c)")
    }

    @Test func onlySafeWordsChangeCase() {
        // `status`, `date`, `name` and `type` are not reserved: they may be names, and names keep their case.
        #expect(format("select status, date, type from Orders") == "SELECT\n  status,\n  date,\n  type\nFROM Orders")
        #expect(format("SELECT a FROM t", SQLFormatOptions(keywordCase: .lower)) == "select a\nfrom t")
        #expect(format("Select a From t", SQLFormatOptions(keywordCase: .preserve)) == "Select a\nFrom t")
        #expect(format("select a from t", SQLFormatOptions(indentWidth: 4)) == "SELECT a\nFROM t")
        #expect(format("select a, b from t", SQLFormatOptions(indentWidth: 4)) == "SELECT\n    a,\n    b\nFROM t")
    }

    @Test func windowFramesAndNullOrdering() {
        #expect(format("select sum(a) over (order by b rows between unbounded preceding and current row) from t order by a nulls last")
            == "SELECT sum(a) OVER (ORDER BY b ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)\nFROM t\nORDER BY a NULLS LAST")
        #expect(format("select sum(a) over (order by b range between 1 preceding and 1 following) from t")
            == "SELECT sum(a) OVER (ORDER BY b RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING)\nFROM t")
        #expect(format("select first, last, nulls, rows from t") == "SELECT\n  first,\n  last,\n  nulls,\n  rows\nFROM t", "names stay names")
    }

    @Test func explainKeepsItsQueryOnTheSameLine() {
        #expect(format("explain analyze select a from t") == "EXPLAIN ANALYZE SELECT a\nFROM t")
        // Option names and values of EXPLAIN / VACUUM are keywords wherever they stand.
        #expect(format("explain (analyze, buffers, format json) select a from t") == "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)\nSELECT a\nFROM t")
        #expect(format("vacuum (verbose, analyze) t") == "VACUUM (VERBOSE, ANALYZE) t")
    }

    @Test func emptyAndWhitespaceInput() {
        #expect(format("") == "")
        #expect(format("   \n  ") == "")
        #expect(format("-- just a note") == "-- just a note")
    }

    @Test func unbalancedAndUnterminatedInputNeverCrash() {
        #expect(format("select (a from t") != nil)
        #expect(format("select a) from t") != nil)
        #expect(format("select 'abc") == "SELECT 'abc")
        #expect(format("select $$abc") == "SELECT $$abc")
        #expect(format("select /* open /* nested */") == "SELECT /* open /* nested */")
    }

    @Test func formattingIsIdempotent() throws {
        for sql in Self.corpus {
            let once = try #require(format(sql), "\(sql)")
            #expect(format(once) == once, "\(sql)")
        }
    }

    /// The safety property: the formatted text has the same tokens (only whitespace and the case of safe keywords differ).
    @Test func randomInputKeepsItsTokens() {
        let alphabet = Array("select from where and or between case when then end ( ) , ; . 'x y' \"a b\" $$ q $$ E'z' -- c\n /* d */ 1 2.5 a b t + - * = <> :: [ ] $1 ->> ")
        var generator = SystemRandomNumberGenerator()
        var refused = 0
        for _ in 0..<3_000 {
            let text = String((0..<Int.random(in: 0...120, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
            guard let formatted = SQLFormatter.format(text) else { // refused: never wrong, at worst unhelpful
                refused += 1
                continue
            }
            #expect(SQLFormatter.sameTokens(text, formatted), "\(text.debugDescription) -> \(formatted.debugDescription)")
            #expect(SQLFormatter.sameStringContinuations(text, formatted), "\(text.debugDescription) -> \(formatted.debugDescription)")
            #expect(SQLFormatter.format(formatted) == formatted, "not idempotent: \(text.debugDescription)")
        }
        #expect(refused < 15, "the formatter should almost never have to refuse (\(refused) of 3000)")
    }

    @Test func cursorPositionsMapAcrossFormatting() throws {
        let original = "select a,b from   t where x=1"
        let formatted = try #require(format(original))
        let afterFrom = (original as NSString).range(of: "from").upperBound
        #expect(SQLFormatter.mapOffset(afterFrom, from: original, to: formatted) == (formatted as NSString).range(of: "FROM").upperBound)
        #expect(SQLFormatter.mapOffset(0, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(original.utf16.count, from: original, to: formatted) == formatted.utf16.count)
        #expect(SQLFormatter.mapOffset(-5, from: original, to: formatted) == 0)
        #expect(SQLFormatter.mapOffset(10_000, from: original, to: formatted) == formatted.utf16.count)
    }

    @Test func selectionsSnapToWholeTokens() throws {
        let text = "select 'a   b' from t; select x,y from u"
        let ns = text as NSString
        let second = ns.range(of: "select x,y from u")
        #expect(try SQLFormatter.formatSelection(in: text, range: second) == SQLFormatReplacement(range: second, text: "SELECT\n  x,\n  y\nFROM u"))
        // Starting inside the string: the whole string joins the selection and keeps its spaces.
        let inside = NSRange(location: ns.range(of: "a   b").location, length: ns.range(of: "from").upperBound - ns.range(of: "a   b").location)
        let string = ns.range(of: "'a   b'")
        #expect(try SQLFormatter.formatSelection(in: text, range: inside)
            == SQLFormatReplacement(range: NSRange(location: string.location, length: ns.range(of: "from").upperBound - string.location), text: "'a   b' FROM"))
        // Part of a name that happens to spell a keyword: the whole name, unchanged.
        let named = "select color from t"
        let color = (named as NSString).range(of: "color")
        #expect(try SQLFormatter.formatSelection(in: named, range: NSRange(location: color.location + 3, length: 2))
            == SQLFormatReplacement(range: color, text: "color"))
        // A fragment that continues a statement: its first word is not a command word.
        let tail = "select a, date from t"
        #expect(try SQLFormatter.formatSelection(in: tail, range: (tail as NSString).range(of: "date from t")).text == "date FROM t")
        // Half a dollar-quoted body: the whole body, unchanged.
        #expect(try SQLFormatter.formatSelection(in: "select $$ a  b $$", range: NSRange(location: 10, length: 3))
            == SQLFormatReplacement(range: NSRange(location: 7, length: 10), text: "$$ a  b $$"))
        // Only whitespace: nothing to do.
        let gap = NSRange(location: 9, length: 3)
        #expect(try SQLFormatter.formatSelection(in: "select 1;   select 2", range: gap) == SQLFormatReplacement(range: gap, text: "   "))
        #expect(throws: SQLFormatError.invalidSelection) { try SQLFormatter.formatSelection(in: text, range: NSRange(location: 0, length: 10_000)) }
        #expect(throws: SQLFormatError.invalidSelection) { try SQLFormatter.formatSelection(in: text, range: NSRange(location: -1, length: 2)) }
    }

    // The re-lex check lets only the tokens the formatter marked change case.
    @Test func theEquivalenceCheckAllowsOnlyMarkedCaseChanges() {
        let select = 0..<6
        let from = 12..<16
        #expect(SQLFormatter.equivalent("select date from t", "SELECT date FROM t", caseChangeable: [select, from]))
        #expect(!SQLFormatter.equivalent("select date from t", "SELECT DATE FROM t", caseChangeable: [select, from]))
        #expect(!SQLFormatter.equivalent("select 'a' from t", "SELECT 'A' FROM t", caseChangeable: [select, 7..<10, 11..<15]),
                "strings never change, whatever the set says")
        #expect(!SQLFormatter.equivalent("select é", "SELECT É", caseChangeable: [select, 7..<8]), "PostgreSQL folds only ASCII letters")
    }

    // The check re-lexes with each server version's number syntax: a split that one version would see is refused.
    @Test func theEquivalenceCheckLexesLikeEveryServerVersion() {
        // Same tokens before PostgreSQL 15 (`123 AS abc`), trailing junk from 15 on: refused.
        #expect(!SQLFormatter.equivalent("select 123abc", "select 123 abc", caseChangeable: []))
        // `0 AS x1F` before 16, one hexadecimal literal from 16 on.
        #expect(!SQLFormatter.equivalent("select 0x1F", "select 0 x1F", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select 1_000", "select 1 _000", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select $1abc", "select $1 abc", caseChangeable: []))
        // Tokens written together stay together, except around punctuation and operators.
        #expect(!SQLFormatter.equivalent("select a::int", "select a :: int", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select t.a", "select t . a", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select a[1:2]", "select a[1 : 2]", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select U&'x'UESCAPE'!'", "select U&'x' UESCAPE '!'", caseChangeable: []))
        #expect(SQLFormatter.equivalent("select a+b,f(x)", "select a + b, f (x)", caseChangeable: []))
        // String continuations: `'a'` newline `'b'` is `'ab'`, `'a' 'b'` an error.
        #expect(!SQLFormatter.equivalent("select 'a'\n'b'", "select 'a' 'b'", caseChangeable: []))
        #expect(!SQLFormatter.equivalent("select 'a' 'b'", "select 'a'\n'b'", caseChangeable: []))
    }

    /// Random selections of random text: either refused or spliced back into a text with the same tokens.
    @Test func randomSelectionsKeepTheWholeText() {
        let alphabet = Array("select from where and or case when end ( ) , ; . 'x y' \"a b\" $$ q $$ -- c\n /* d */ 1 a t + - = :: [ ] ")
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String((0..<Int.random(in: 1...80, using: &generator)).compactMap { _ in alphabet.randomElement(using: &generator) })
            let length = (text as NSString).length
            let lower = Int.random(in: 0...length, using: &generator)
            let range = NSRange(location: lower, length: Int.random(in: 0...(length - lower), using: &generator))
            guard range.length > 0, let replacement = try? SQLFormatter.formatSelection(in: text, range: range) else { continue }
            // Every token the selection touches is replaced whole: tokens as the formatter lays them out (the check covers
            // every version's reading of the spliced text).
            let touched = SQLLexer(text, syntax: SQLFormatter.layoutSyntax).tokens()
                .filter { $0.range.upperBound > range.location && $0.range.lowerBound < NSMaxRange(range) }
            for token in touched {
                #expect(replacement.range.location <= token.range.lowerBound && token.range.upperBound <= NSMaxRange(replacement.range),
                        "\(text.debugDescription) \(range) -> \(replacement.range)")
            }
            let spliced = (text as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
            #expect(SQLFormatter.sameTokens(text, spliced), "\(text.debugDescription) \(range) -> \(spliced.debugDescription)")
            #expect(SQLFormatter.sameStringContinuations(text, spliced), "\(text.debugDescription) \(range) -> \(spliced.debugDescription)")
        }
    }

    @Test func trailingSpacesOfLineCommentsAreKept() {
        #expect(format("select a -- note   \nfrom t") == "SELECT a -- note   \nFROM t")
    }

    @Test func aMegabyteScriptFormatsQuickly() throws {
        let statement = "select o.id, sum(o.total) total, case when o.x > 1 then 'a' when o.x < 0 then 'b' else 'c' end k "
            + "from shop.orders o left join shop.customers c on o.cid = c.id and c.city in ('KL', 'PG') "
            + "where o.d between '2024-01-01' and '2024-12-31' and o.status = 'paid'::text group by o.id, k order by total desc limit 10;\n"
        let script = String(repeating: statement, count: 1_048_576 / statement.utf8.count + 1)
        let started = ContinuousClock.now
        let formatted = try #require(format(script))
        #expect(ContinuousClock.now - started < .seconds(20), "debug build bound; release is far faster")
        #expect(formatted.count > script.count)
    }

    // MARK: Which words change case

    /// pg_get_keywords() catcode 'R' on PostgreSQL 13, 17 and 18 (the integration tests check it on each server).
    @Test func caseChangesAnywhereOnlyForServerReservedWords() {
        #expect(SQLFormatter.reservedKeywords.count == 77)
        #expect(!SQLFormatter.reservedKeywords.contains("SYSTEM_USER"), "reserved only from PostgreSQL 16")
        // 'T' words: functions and types may be named so.
        for word in ["JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL", "IS", "ISNULL", "NOTNULL", "LIKE", "ILIKE",
                     "SIMILAR", "OVERLAPS", "VERBOSE", "CONCURRENTLY", "CURRENT_SCHEMA", "COLLATION", "BINARY", "FREEZE", "TABLESAMPLE",
                     "AUTHORIZATION"] {
            #expect(!SQLFormatter.reservedKeywords.contains(word), "\(word)")
        }
        #expect(SQLFormatter.reservedKeywords.isSubset(of: SQLKeywords.reserved), "the app quotes every reserved word")
        for word in SQLFormatter.reservedKeywords {
            #expect(SQLLexer.tokenize(word.lowercased()).map(\.kind) == [.keyword], "\(word)")
        }
        #expect(format("select localtimestamp, current_catalog") == "SELECT\n  LOCALTIMESTAMP,\n  CURRENT_CATALOG")
    }

    // Type-and-function-name keywords ('T') change case only where their position makes them keywords.
    @Test func typeAndFunctionNameKeywordsChangeCaseOnlyAsKeywords() {
        #expect(format("select left(name, 2), right(name, 1), current_schema, join(a) from t")
            == "SELECT\n  left(name, 2),\n  right(name, 1),\n  current_schema,\n  join(a)\nFROM t")
        #expect(format("select * from a left outer join b on true natural full join c cross join d inner join e using (id)")
            == "SELECT *\nFROM a\nLEFT OUTER JOIN b\n  ON TRUE\nNATURAL FULL JOIN c\nCROSS JOIN d\nINNER JOIN e USING (id)")
        #expect(format("select count(*) filter (where a like 'x%') from (a join b on b.id = a.id) j")
            == "SELECT count(*) FILTER (WHERE a LIKE 'x%')\nFROM (a JOIN b ON b.id = a.id) j")
        #expect(format("select a from t where a like 'x%' and b not ilike 'y' and c is not null and d isnull and e similar to 'z' and (f, g) overlaps (h, i)")
            == "SELECT a\nFROM t\nWHERE a LIKE 'x%'\n  AND b NOT ILIKE 'y'\n  AND c IS NOT NULL\n  AND d ISNULL\n  AND e SIMILAR TO 'z'\n  AND (f, g) OVERLAPS (h, i)")
        #expect(format("select * from t tablesample bernoulli (10)") == "SELECT *\nFROM t TABLESAMPLE bernoulli(10)")
        #expect(format("create index concurrently if not exists i on t (a); refresh materialized view concurrently v; vacuum full freeze verbose analyze t; explain verbose select 1")
            == "CREATE INDEX CONCURRENTLY IF NOT EXISTS i ON t (a);\n\nREFRESH MATERIALIZED VIEW CONCURRENTLY v;\n\nVACUUM FULL FREEZE VERBOSE ANALYZE t;\n\nEXPLAIN VERBOSE SELECT 1")
        // At the start of a column-list item LIKE can only be the LIKE clause ('T' words cannot name columns).
        #expect(format("create table t (like u including all, a int)") == "CREATE TABLE t (\n  LIKE u including ALL,\n  a int\n)")
        #expect(format("create schema s authorization joe; set session authorization joe")
            == "CREATE SCHEMA s AUTHORIZATION joe;\n\nSET SESSION AUTHORIZATION joe")
        #expect(format("select a from t where a is distinct from b and c is not distinct from d")
            == "SELECT a\nFROM t\nWHERE a IS DISTINCT FROM b\n  AND c IS NOT DISTINCT FROM d")
    }

    // A reserved word after `.` or as a label after AS is a name (PostgreSQL accepts any keyword there).
    @Test func reservedWordsUsedAsNamesKeepTheirText() {
        #expect(format("select t.from, t.order as select, 1 as from from t") == "SELECT\n  t.from,\n  t.order AS select,\n  1 AS from\nFROM t")
        #expect(format("select x.select from (select 1 as select) x") == "SELECT x.select\nFROM (\n  SELECT 1 AS select\n) x")
        #expect(format("select * from t as values join u as set on true") == "SELECT *\nFROM t AS values\nJOIN u AS set\n  ON TRUE")
        #expect(format("insert into t (a) values (1) returning a as order") == "INSERT INTO t (a)\nVALUES (1)\nRETURNING a AS order")
    }

    // Words that are keywords only in some positions keep their text everywhere else.
    @Test func positionalKeywordsChangeCaseOnlyInProvenPositions() {
        #expect(format("select 1 following, 2 preceding, rows, range, nulls first from t")
            == "SELECT\n  1 following,\n  2 preceding,\n  rows,\n  range,\n  nulls first\nFROM t")
        #expect(format("select * from generate_series(1, 2) over, generate_series(1, 2) within group by 1")
            == "SELECT *\nFROM generate_series(1, 2) over, generate_series(1, 2) within\nGROUP BY 1")
        #expect(format("select * from a join b on conflict = 1") == "SELECT *\nFROM a\nJOIN b\n  ON conflict = 1")
        // The spec scenario.
        #expect(format("select t.from, 1 following, rows from t join u on conflict = 1")
            == "SELECT\n  t.from,\n  1 following,\n  rows\nFROM t\nJOIN u\n  ON conflict = 1")
        #expect(format("with recursive as (select 1) select * from recursive") == "WITH recursive AS (\n  SELECT 1\n)\nSELECT *\nFROM recursive")
        #expect(format("with recursive r(n) as (select 1) select * from r") == "WITH RECURSIVE r(n) AS (\n  SELECT 1\n)\nSELECT *\nFROM r")
        #expect(format("update set set a = 1") == "UPDATE set\nSET a = 1")
        #expect(format("update only t as set set a = 1") == "UPDATE ONLY t AS set\nSET a = 1")
        #expect(format("insert into values values (1); insert into t default values")
            == "INSERT INTO values\nVALUES (1);\n\nINSERT INTO t DEFAULT VALUES")
        #expect(format("drop table exists; create table if (a int)") == "DROP TABLE exists;\n\nCREATE TABLE if (\n  a int\n)")
        #expect(format("drop owned by admin") == "DROP OWNED BY admin")
        #expect(format("select a, cube(1, 2) from t group by cube (a, b)") == "SELECT\n  a,\n  cube(1, 2)\nFROM t\nGROUP BY CUBE (a, b)")
        #expect(format("select substring(s from 1 for update), skip locked, nowait from t")
            == "SELECT\n  substring(s FROM 1 FOR update),\n  skip locked,\n  nowait\nFROM t")
        #expect(format("create table t (language text, returns int, each int)")
            == "CREATE TABLE t (\n  language text,\n  returns int,\n  each int\n)")
    }

    // MERGE actions (PostgreSQL 15+) and a rule's ON SELECT event are keywords by position.
    @Test func mergeActionsAndRuleEvents() {
        #expect(format("merge into t using s on t.id = s.id when matched and s.x then update set a = s.a when matched then delete "
                       + "when not matched then insert (id) values (s.id)")
            == "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED AND s.x THEN UPDATE SET a = s.a WHEN MATCHED THEN DELETE "
                + "WHEN NOT MATCHED THEN INSERT (id) VALUES (s.id)")
        #expect(format("merge into t using s on case when s.a then update end when matched then do nothing")
            == "MERGE INTO t USING s ON CASE WHEN s.a THEN update END WHEN MATCHED THEN DO NOTHING")
        #expect(format("create rule r as on select to t do instead select * from u")
            == "CREATE RULE r AS ON SELECT TO t DO INSTEAD\nSELECT *\nFROM u")
    }

    @Test func windowFramesSortItemsAndRowCountsAreProven() {
        #expect(format("select sum(a) over (order by rows rows 2 preceding exclude current row) from t order by a desc nulls first offset 1 rows fetch next 2 rows with ties")
            == "SELECT sum(a) OVER (ORDER BY rows ROWS 2 PRECEDING EXCLUDE CURRENT ROW)\nFROM t\nORDER BY a DESC NULLS FIRST\nOFFSET 1 ROWS\nFETCH NEXT 2 ROWS WITH TIES")
        #expect(format("select array_agg(x order by y nulls last) from t") == "SELECT array_agg(x ORDER BY y NULLS LAST)\nFROM t")
        #expect(format("create index i on t (a desc nulls last)") == "CREATE INDEX i ON t (a DESC NULLS LAST)")
        #expect(format("select sum(a) over (order by b groups between 1 preceding and current row exclude no others) from t")
            == "SELECT sum(a) OVER (ORDER BY b GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE NO OTHERS)\nFROM t")
        #expect(format("select sum(a) over w from t window w as (partition by b range between unbounded preceding and unbounded following)")
            == "SELECT sum(a) OVER w\nFROM t\nWINDOW w AS (PARTITION BY b RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)")
    }

    // MARK: Layout safety

    @Test func commentsOnOneLineKeepTheirOrder() {
        #expect(format("select a\n/* c1 */ /* c2 */ from t") == "SELECT a\n/* c1 */ /* c2 */\nFROM t")
        #expect(format("select a\n/* c1 */ -- c2\nfrom t") == "SELECT a\n/* c1 */ -- c2\nFROM t")
        #expect(format("select a,\n/* c1 */ /* c2 */ /* c3 */ b from t") == "SELECT\n  a,\n  /* c1 */ /* c2 */ /* c3 */\n  b\nFROM t")
    }

    // Whitespace goes between tokens that were written together only around punctuation and operators.
    @Test func tokensWrittenTogetherStayTogether() {
        // PostgreSQL 15+ rejects these as trailing junk; a space would turn them into aliases (or another error).
        #expect(format("select 123abc, 0x1Fg, $1abc, 1e+x, 1.5e-y from t") == "SELECT\n  123abc,\n  0x1Fg,\n  $1abc,\n  1e+x,\n  1.5e-y\nFROM t")
        #expect(format("select date'2024-01-01', x'1F', 'a'$$b$$, \"x\"from t")
            == "SELECT\n  date'2024-01-01',\n  x'1F',\n  'a'$$b$$,\n  \"x\"FROM t")
        // Around operators and punctuation, spacing is the formatter's job; never around `::` and `.`.
        #expect(format("select a+b,c::int,t.d from t where(a=-1)") == "SELECT\n  a + b,\n  c::int,\n  t.d\nFROM t\nWHERE (a = -1)")
        #expect(format("select arr[1:-1], j->>'k', j#>>'{a}', j@>'{}', f(x=>1) from t")
            == "SELECT\n  arr[1:-1],\n  j ->> 'k',\n  j #>> '{a}',\n  j @> '{}',\n  f(x => 1)\nFROM t")
    }

    @Test func deepNestingIsCappedAndRunawayGrowthRefused() throws {
        let nested = String(repeating: "select (", count: 40) + "1" + String(repeating: ")", count: 40)
        let formatted = try #require(format(nested))
        let deepest = formatted.components(separatedBy: "\n").map { line in line.prefix { $0 == " " }.count }.max() ?? 0
        #expect(deepest <= SQLFormatter.maximumIndentLevel * 2)
        #expect(format(formatted) == formatted)
        // 500 levels: fine with 2 spaces, but with 8 the text would grow more than allowed.
        let deep = String(repeating: "select (", count: 500) + "1" + String(repeating: ")", count: 500)
        #expect(format(deep, SQLFormatOptions(indentWidth: 2)) != nil)
        #expect(throws: SQLFormatError.tooComplex) { try SQLFormatter.formatted(deep, options: SQLFormatOptions(indentWidth: 8)) }
        let parentheses = SQLFormatter.maximumNesting
        #expect(format(String(repeating: "(", count: parentheses) + "1" + String(repeating: ")", count: parentheses)) != nil)
        #expect(throws: SQLFormatError.tooComplex) {
            try SQLFormatter.formatted(String(repeating: "(", count: parentheses + 1) + "1" + String(repeating: ")", count: parentheses + 1))
        }
    }

    @Test func formattingStopsWhenItsTaskIsCancelled() async {
        let script = String(repeating: "select a, b from t where x = 1;\n", count: 5_000)
        let outcome = await Task.detached { () -> SQLFormatError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(SQLFormatError) {
                _ = try SQLFormatter.formatted(script)
                return nil
            } catch {
                return error
            }
        }.value
        #expect(outcome == .cancelled)
    }

    /// `:` runs (`::`, `:=`, slices) next to operators and brackets: same tokens, and a second pass changes nothing.
    @Test func colonRunsAreIdempotent() {
        let pieces = [":", ":", "::", ":=", "[", "]", "a", "1", "-", "=", ">", " ", " ", "\n", "x", "(", ")", ",", "'s'", "$1", ".", "->>", "=>",
                      "e", "+", "--c\n", "/*k*/", "select", "from"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<4_000 {
            let text = (0..<Int.random(in: 1...40, using: &generator)).map { _ in pieces.randomElement(using: &generator) ?? "" }.joined()
            guard let formatted = SQLFormatter.format(text) else { continue }
            #expect(SQLFormatter.sameTokens(text, formatted), "\(text.debugDescription) -> \(formatted.debugDescription)")
            #expect(SQLFormatter.format(formatted) == formatted, "not idempotent: \(text.debugDescription) -> \(formatted.debugDescription)")
        }
    }

    // MARK: Defect classes from the reviews

    // A word right before or after `.` is part of a qualified name: it never opens or closes a structure (CASE … END, a
    // clause, OVER / FILTER / WITHIN GROUP) and never changes case.
    @Test func aWordNextToADotIsAlwaysAName() throws {
        #expect(format("select x.end, end.x, case.x, over.a, filter.b, within.c from t")
            == "SELECT\n  x.end,\n  end.x,\n  case.x,\n  over.a,\n  filter.b,\n  within.c\nFROM t")
        // `end.x` does not close the CASE (it stays one line: no END).
        #expect(format("select case when a then b else c end.x from t") == "SELECT CASE WHEN a THEN b ELSE c end.x\nFROM t")
        #expect(format("select a from t order by.x") == "SELECT a\nFROM t ORDER by.x")
        #expect(format("select percentile_cont(0.5) within group.x from t") == "SELECT percentile_cont(0.5) within group.x\nFROM t")
        #expect(format("select end /* c */ . x, y. /* d */ from from t") == "SELECT\n  end /* c */ .x,\n  y. /* d */ from\nFROM t")
        // A selection that starts or ends next to a `.` outside it.
        let text = "select t.end, case.x from t"
        let ns = text as NSString
        #expect(try SQLFormatter.formatSelection(in: text, range: ns.range(of: "end, case")).text == "end, case")
    }

    // VALUES is a query only before its rows where a query (or an INSERT's rows) may stand: after a set operator, not after
    // SELECT DISTINCT / ALL; an alias or a column called `values` keeps its text and its line.
    @Test func setOperatorsAndValuesNeedAProvenQuery() {
        #expect(format("select distinct values from t") == "SELECT DISTINCT values\nFROM t")
        #expect(format("select all values, set from t") == "SELECT ALL\n  values,\n  set\nFROM t")
        #expect(format("select 1 union all values (2) except distinct (values (3))")
            == "SELECT 1\nUNION ALL\nVALUES (2)\nEXCEPT DISTINCT (VALUES (3))")
        #expect(format("select * from (select 1) s(values) join (select 2) values (a) on true")
            == "SELECT *\nFROM (\n  SELECT 1\n) s(values)\nJOIN (\n  SELECT 2\n) values (a)\n  ON TRUE")
        #expect(format("insert into t select values from u") == "INSERT INTO t\nSELECT values\nFROM u")
        #expect(format("insert into t select * from (select 1) values (a)") == "INSERT INTO t\nSELECT *\nFROM (\n  SELECT 1\n) values (a)")
        #expect(format("insert into t (a) select 1 from u where values = 1") == "INSERT INTO t (a)\nSELECT 1\nFROM u\nWHERE values = 1")
        #expect(format("insert into t default values returning values") == "INSERT INTO t DEFAULT VALUES\nRETURNING values")
        #expect(format("insert into t overriding system value values (1)") == "INSERT INTO t overriding system value\nVALUES (1)")
        #expect(format("merge into t using (select 1) values (a) on true when not matched then insert values (1)")
            == "MERGE INTO t USING (SELECT 1) values (a) ON TRUE WHEN NOT MATCHED THEN INSERT VALUES (1)")
        #expect(format("with x as (insert into t values (1) returning values) select 1")
            == "WITH x AS (INSERT INTO t VALUES (1) RETURNING values)\nSELECT 1")
    }

    // Clause words in name slots (an index's table, a policy's command) are names or plain words, and lists of columns
    // called `values` / `set` still break.
    @Test func clauseWordsInNameSlots() {
        #expect(format("create index i on rows (a); create index i on filter (a desc nulls last); create index i on values (a)")
            == "CREATE INDEX i ON rows (a);\n\nCREATE INDEX i ON filter (a DESC NULLS LAST);\n\nCREATE INDEX i ON values (a)")
        #expect(format("create index i on set (a); create index i on over using gin (a)")
            == "CREATE INDEX i ON set (a);\n\nCREATE INDEX i ON over USING gin (a)")
        #expect(format("select values, set from t group by values, set order by values")
            == "SELECT\n  values,\n  set\nFROM t\nGROUP BY\n  values,\n  set\nORDER BY values")
        #expect(format("create policy p on t for select using (true)") == "CREATE POLICY p ON t FOR SELECT USING (TRUE)")
        #expect(format("create view v as select 1; create table t as values (1); create view w as with x as (select 1) select * from x")
            == "CREATE VIEW v AS\nSELECT 1;\n\nCREATE TABLE t AS\nVALUES (1);\n\nCREATE VIEW w AS WITH x AS (\n  SELECT 1\n)\nSELECT *\nFROM x")
    }

    // PostgreSQL folds only ASCII letters: `ﬁrst`, `ſelect` (long s) and `diﬆinct` are names, so `nulls ﬁrst` proves nothing
    // and none of them changes case (Unicode would upper-case ſ to S and ﬆ to ST).
    @Test func keywordsAreASCIIWords() {
        #expect(format("select ﬁrst, ﬁlter from t order by a nulls ﬁrst") == "SELECT\n  ﬁrst,\n  ﬁlter\nFROM t\nORDER BY a nulls ﬁrst")
        #expect(format("select 1 ſelect") == "SELECT 1 ſelect")
        #expect(format("select diﬆinct ﬁrst from t") == "SELECT diﬆinct ﬁrst\nFROM t")
        // The check compares case on ASCII letters only: any change to another character is a mismatch, even on a word
        // marked changeable and of the same length.
        #expect(!SQLFormatter.equivalent("select xſ", "select XS", caseChangeable: [0..<6, 7..<9]))
        #expect(!SQLFormatter.equivalent("select 1 ſelect", "select 1 SELECT", caseChangeable: [0..<6, 9..<15]))
        #expect(!SQLFormatter.equivalent("select diﬆinct", "select DISTINCT", caseChangeable: [0..<6, 7..<14]))
        #expect(SQLFormatter.equivalent("select xs", "select XS", caseChangeable: [0..<6, 7..<9]))
    }

    // CRLF (or CR) input comes out with the same line breaks everywhere.
    @Test func lineBreaksFollowTheInput() throws {
        #expect(format("select a, b\r\nfrom t -- c\r\nwhere x = 1;\r\nselect 'a'\r\n'b'\r\n")
            == "SELECT\r\n  a,\r\n  b\r\nFROM t -- c\r\nWHERE x = 1;\r\n\r\nSELECT 'a'\r\n  'b'\r\n")
        #expect(format("select a, b\rfrom t") == "SELECT\r  a,\r  b\rFROM t")
        #expect(format("select a, b\nfrom t") == "SELECT\n  a,\n  b\nFROM t")
        // A line break inside a string or comment is the token's own; the text's breaks are between tokens.
        #expect(format("select 'x\r\ny', /* a\r\nb */ b\nfrom t") == "SELECT\n  'x\r\ny', /* a\r\nb */\n  b\nFROM t")
        #expect(format("select 'x\r\ny', b from t") == "SELECT\r\n  'x\r\ny',\r\n  b\r\nFROM t", "the only evidence")
        let text = "select 1;\r\nselect a, b from t"
        let second = (text as NSString).range(of: "select a, b from t")
        #expect(try SQLFormatter.formatSelection(in: text, range: second).text == "SELECT\r\n  a,\r\n  b\r\nFROM t")
    }

    // Brackets: `ARRAY[1,2,3]` stays one item, and a keyword keeps the input's spacing before `[`.
    @Test func arrayConstructorsAndBrackets() {
        #expect(format("select array[1,2,3], array [4,5], a[1:2], b [1] from t")
            == "SELECT\n  ARRAY[1, 2, 3],\n  ARRAY [4, 5],\n  a[1:2],\n  b[1]\nFROM t")
        #expect(format("select array[1,2,3]") == "SELECT ARRAY[1, 2, 3]")
        #expect(format("create table t (a int[] default array[1,2,3], b int [])")
            == "CREATE TABLE t (\n  a int[] DEFAULT ARRAY[1, 2, 3],\n  b int []\n)")
        #expect(format("insert into t values (array[1,2], array[[3,4],[5,6]])") == "INSERT INTO t\nVALUES (ARRAY[1, 2], ARRAY[[3, 4], [5, 6]])")
    }

    // Input adjacency the server cares about: never split, wherever the layout puts breaks.
    @Test func adjacentTokensAreNeverSeparated() {
        #expect(format("select U&'d!0061t'UESCAPE'!', u&'x' uescape '!', $1::int, a[1:2], j->>'k', j@>'{}', x@-1 from t")
            == "SELECT\n  U&'d!0061t'UESCAPE'!',\n  u&'x' uescape '!',\n  $1::int,\n  a[1:2],\n  j ->> 'k',\n  j @> '{}',\n  x @- 1\nFROM t")
        #expect(format("select (select 1)::text, a[(select 1):2] from t")
            == "SELECT\n  (\n    SELECT 1\n  )::text,\n  a[(\n    SELECT 1\n  ):2]\nFROM t")
    }

    // Numbers keep the server's token boundaries for every version (see the lexer tests). `1e'…'` is `1` and an E'…'
    // string before 15 but trailing junk and a '…' string after: the texts read differently stay exactly as written.
    @Test func numbersStayAsWritten() throws {
        #expect(format("select 1e'a\\'b', x from t") == "SELECT 1e'a\\'b', x from t", "after `'a\\'` 16+ reads an open string")
        let text = " 1e'n: emfd dn er-1   x"
        let replacement = try SQLFormatter.formatSelection(in: text, range: NSRange(location: 3, length: 4))
        #expect(SQLFormatter.sameTokens(text, (text as NSString).replacingCharacters(in: replacement.range, with: replacement.text)))
        #expect(format("select 0x1F, 1_000, 0o19, 1e1_0, 123abc, 1e+x, $1abc, 1..2, t.5, 1_.5 from t")
            == "SELECT\n  0x1F,\n  1_000,\n  0o19,\n  1e1_0,\n  123abc,\n  1e+x,\n  $1abc,\n  1..2,\n  t.5,\n  1_.5\nFROM t")
    }

    // No option can make the formatter trap: the indent is clamped to 1…8 spaces.
    @Test func optionsAreClamped() {
        #expect(SQLFormatOptions(indentWidth: -1).indentWidth == 1)
        #expect(SQLFormatOptions(indentWidth: Int.min).indentWidth == 1)
        #expect(SQLFormatOptions(indentWidth: Int.max).indentWidth == 8)
        #expect(format("select a, b from t", SQLFormatOptions(indentWidth: -1)) == "SELECT\n a,\n b\nFROM t")
    }

    /// Linear time on input built to defeat look-aheads: nesting, unclosed CASE, statements that never end.
    @Test func adversarialInputFormatsInLinearTime() throws {
        let count = 50_000
        let inputs = [
            String(repeating: "select (", count: count),
            String(repeating: "select (", count: count) + "1" + String(repeating: ")", count: count),
            String(repeating: "explain ", count: count) + "select 1",
            String(repeating: "case ", count: count),
            "select " + String(repeating: "a, ", count: count) + "b from t",
            String(repeating: "/* c */\n", count: count) + "select 1",
            "select a" + String(repeating: "[", count: count),
            "select " + String(repeating: "a.", count: count) + "b",
            "select 1 from t where " + String(repeating: "a and ", count: count) + "b",
            "select * from t " + String(repeating: "outer ", count: count),
            "select * from t " + String(repeating: "natural ", count: count) + "join u",
            "select * from t " + String(repeating: "left outer ", count: count),
        ]
        // Compared with ordinary SQL of the same size formatted on the same machine at the same moment, so the bound holds on
        // a busy machine: linear work costs a small multiple of it, quadratic work (`explain` × 50,000 took 72 s, `outer`
        // runs 5.5 s per 384 KB in release) tens of times more.
        let ordinary = String(repeating: "select a, b from t where c = 1 and d in (1, 2);\n", count: 6_000)
        let perUnit = { (text: String) -> Double in
            let started = ContinuousClock.now
            _ = try? SQLFormatter.formatted(text)
            let elapsed = ContinuousClock.now - started
            return (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18) / Double(text.utf16.count)
        }
        let baseline = min(perUnit(ordinary), perUnit(ordinary))
        for input in inputs {
            let outcome = Result { () throws(SQLFormatError) in try SQLFormatter.formatted(input) }
            if case let .failure(error) = outcome { #expect(error == .tooComplex) }
            let cost = perUnit(input)
            #expect(cost < 8 * baseline + 1e-6, "\(input.prefix(24).debugDescription)…: \(cost / baseline)× ordinary SQL per character")
        }
    }

    // MARK: Independent review

    // standard_conforming_strings: off on the server, `'don\'t   panic'` is one string. The check reads every text both
    // ways, so a layout that would change what either reading sees is refused; backslashes that read the same stay fine.
    @Test func stringsAreCheckedWithAndWithoutStandardConformingStrings() {
        #expect(throws: SQLFormatError.notEquivalent) { try SQLFormatter.formatted("SELECT 'don\\'t   panic'") }
        #expect(throws: SQLFormatError.notEquivalent) { try SQLFormatter.formatted("select 'C:\\dir\\' as p,   x from t") }
        #expect(format("select 'C:\\dir', '\\d+', E'it\\'s' from t") == "SELECT\n  'C:\\dir',\n  '\\d+',\n  E'it\\'s'\nFROM t")
    }

    // A vertical tab is whitespace to PostgreSQL 17/18 and an error to 13: formatting would turn the error into a success.
    @Test func verticalTabsBetweenTokensAreRefused() throws {
        #expect(throws: SQLFormatError.versionDependent) { try SQLFormatter.formatted("SELECT\u{0B}1") }
        #expect(throws: SQLFormatError.versionDependent) { try SQLFormatter.formatted("\u{0B}select 1") }
        #expect(format("select 'a\u{0B}b' -- \u{0B}\nfrom t") == "SELECT 'a\u{0B}b' -- \u{0B}\nFROM t", "inside tokens it is text")
        let text = "select 1;\u{0B}select a,b from t"
        #expect(try SQLFormatter.formatSelection(in: text, range: (text as NSString).range(of: "select a,b from t")).text
            == "SELECT\n  a,\n  b\nFROM t")
        #expect(throws: SQLFormatError.versionDependent) { try SQLFormatter.formatSelection(in: text, range: NSRange(location: 0, length: 12)) }
    }

    // A run of operator characters is one token however long ("operator too long" on the server stays that error).
    @Test func longOperatorsStayOneToken() throws {
        let run = String(repeating: "@", count: 70) + "-"
        #expect(try SQLFormatter.formatted("SELECT 1 \(run)2") == "SELECT 1 \(run) 2")
    }

    // A NUL cannot be sent: text containing one is never formatted (`a\0b` would become `a \0 b`).
    @Test func textWithANulCharacterIsRefused() {
        #expect(throws: SQLFormatError.nulCharacter) { try SQLFormatter.formatted("select a\u{0}b from t") }
        #expect(throws: SQLFormatError.nulCharacter) { try SQLFormatter.formatted("select 'a\u{0}b'") }
        #expect(throws: SQLFormatError.nulCharacter) { try SQLFormatter.formatSelection(in: "select 1;\u{0} select 2", range: NSRange(location: 0, length: 8)) }
    }

    // Bit strings end at their first quote, as on the server: `B'10''01'` stays as written.
    @Test func bitStringsEndAtTheirFirstQuote() {
        #expect(format("select B'10''01', X'1F''2E' from t") == "SELECT\n  B'10''01',\n  X'1F''2E'\nFROM t")
    }

    // Only proven positions change case: a parenthesised query after EXPLAIN is not an option list, a `rows` right after
    // ORDER BY is a sort key, and a column list is not a statement body.
    @Test func unprovenPositionsKeepTheirCase() {
        #expect(format("EXPLAIN (select my_col, rows from my_table)") == "EXPLAIN (\n  SELECT\n    my_col,\n    rows\n  FROM my_table\n)")
        #expect(format("explain (analyze, format json) select 1") == "EXPLAIN (ANALYZE, FORMAT JSON)\nSELECT 1")
        #expect(format("select sum(x) over (order by rows between 1 preceding and current row) from t")
            == "SELECT sum(x) OVER (ORDER BY rows BETWEEN 1 preceding AND current row)\nFROM t")
        #expect(format("select sum(x) over (order by a, rows rows between 1 preceding and current row) from t")
            == "SELECT sum(x) OVER (ORDER BY a, rows ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)\nFROM t")
        #expect(format("CREATE TABLE zz (update int, set int)") == "CREATE TABLE zz (\n  update int,\n  set int\n)")
        #expect(format("CREATE INDEX ON t (update text_pattern_ops)") == "CREATE INDEX ON t (update text_pattern_ops)")
        // Statement bodies still are: a CTE, a rule action, COPY's query.
        #expect(format("with x as (update t set a = 1 returning *) select 1") == "WITH x AS (UPDATE t SET a = 1 RETURNING *)\nSELECT 1")
        #expect(format("copy (delete from t returning *) to stdout") == "COPY (DELETE FROM t RETURNING *) TO stdout")
        #expect(format("create rule r as on insert to t do also (update u set a = 1; delete from v)")
            == "CREATE RULE r AS ON INSERT TO t DO ALSO (UPDATE u SET a = 1; DELETE FROM v)")
    }

    static let corpus = [
        "select a, b from t where x = 1 and y = 2 order by a",
        "select * from (select a from t) s where a in (select a from u)",
        "with x as (select 1), y as (select 2) select * from x join y on x.a = y.a",
        "select case when a then 1 when b then 2 else 3 end x from t; update t set a = 1, b = 2 returning *",
        "create table t (a int, b varchar(10), primary key (a)) partition by list (a)",
        "select 'a' -- c\n, b from t /* x */ where a between 1 and 2 and b = 1",
        "insert into t (a, b) values (1, 2), (3, 4) on conflict (a) do nothing; delete from t where a = 1",
        "select 'a'\n'b', x::int[], $1, arr[1:2] from t",
        "create function f() returns int language sql as $$ select 1 $$; do $$ begin null; end $$",
        "select sum(a) over (partition by b order by c rows between unbounded preceding and current row) from t",
        "select t.from, 1 as order from t where a like 'x' and b is distinct from c",
        "select a\n/* c1 */ /* c2 */ from t; select 123abc, 1e+x, 'a'$$b$$ from t",
        "with recursive as (select 1) update set set a = 1 from recursive",
        "select a::text[]::int[], arr[1:-1], x := 1, a: :b from t",
    ]
}
