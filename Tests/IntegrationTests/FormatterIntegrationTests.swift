import CcinnPsqlKit
import Foundation
import PostgresKit
import Testing

/// Formatted statements run on PostgreSQL and do exactly what the originals do.
@Suite("SQL formatter integration", .enabled(if: IT.enabled), .serialized)
struct FormatterIntegrationTests {
    static let queries = [
        "select o.id, c.name, count(i.product_id) n, sum(i.quantity * i.unit_price) as total from shop.orders o join shop.customers c "
            + "on c.id = o.customer_id left join shop.order_items i on i.order_id = o.id where o.status in ('paid','shipped') "
            + "and o.placed_at between '2000-01-01' and '2100-01-01' group by o.id, c.name having count(*) > 0 order by total desc nulls last, o.id limit 5",
        "with paid as (select * from shop.orders where status = 'paid'), cust as (select distinct customer_id from paid) "
            + "select case when count(*) > 10 then 'many' when count(*) > 0 then 'some' else 'none' end k, count(*) from cust",
        "select product_id, sum(quantity) over (partition by order_id order by product_id rows between unbounded preceding and current row) s "
            + "from shop.order_items i join shop.products p on p.id = i.product_id order by 1, 2 limit 10",
        "select 'a'\n'b' as concatenated, E'x\\ty' as e, $$ dollar  body $$ as d, -1 * 2 as m, 2::numeric(5,2) as c, "
            + "(array[1,2,3])[2:3] as slice, '{\"a\":1}'::jsonb ->> 'a' as j, 5 - -2 as twice, 3 =-3 as neg",
        "select distinct on (customer_id) customer_id, id from shop.orders order by customer_id, id desc",
        "select * from shop.paid_orders order by 1 limit 3",
        "select count(*) filter (where status = 'paid'), count(*) from shop.orders",
        "select p.title from shop.products p where exists (select 1 from shop.order_items i where i.product_id = p.id) order by 1 limit 3",
        "values (1, 'a'), (2, 'b')",
        "select x.n from generate_series(1, 3) as x(n) order by 1 fetch first 2 rows only",
        "explain (costs off, format json) select * from shop.orders where id = 1",
        "/* note */ select -- first\n id, -(total).amount as minus from shop.orders order by id limit 3 -- end",
    ]

    /// Statements whose words look like keywords, or whose tokens were written together: the formatted text must give
    /// the same rows, or fail with the same error, on every server version (`123abc` is `123 AS abc` before 15 and an error
    /// after).
    static let lookalikes = [
        "with recursive as (select 1 as from, 2 as order) select r.from, r.order as select from recursive r",
        "with recursive r(n) as (select 1 union all select n + 1 from r where n < 3) select n as values from r order by n desc nulls first",
        "select x.n as rows from generate_series(1, 3) as x(n) order by 1 offset 1 rows fetch next 1 rows only",
        "select sum(n) over (order by n rows between 1 preceding and current row exclude current row) from generate_series(1, 4) n",
        "select left('abc', 2), right('abc', 1), current_schema, 'abc' like 'a%', 'abc' similar to 'a%', null isnull",
        "select * from generate_series(1, 2) over",
        "select 123abc",
        "select 1e+x",
        "select 0x1Fg",
        "select 'a'$$b$$",
        "select 'a' 'b'",
        "select 'a'\n'b'",
        "select date'2024-01-01', interval'1 day', x'1F', b'101'",
        // Keyword-named names: next to `.`, columns and aliases called `values` / `set`, a CASE whose `end` is a qualifier.
        "select x.end, x.filter, x.over, x.within from (select 1 as end, 2 as filter, 3 as over, 4 as within) x",
        "select distinct values from (select 1 as values) t",
        "select all values, set from (select 1 as values, 2 as set) t group by values, set order by values",
        "select * from (select 1) s(values) join (select 2) values (a) on true",
        "select 1 union all values (2) except distinct (values (3)) order by 1",
        "with t(values) as (values (1)) select values from t where values > 0",
        "select case when true then 1 else 2 end.x",
        "select ﬁrst from (select 1 as ﬁrst) t order by 1 nulls ﬁrst",
        // Numbers the versions lex differently, and tokens the server sees as one.
        "select 0x1F, 1_000, 0o17, 0b101, 1e1_0, 1_000.5",
        "select 0o19", "select 1_", "select 1..2", "select t.5 from (select 1) t", "select 1as",
        // Brackets, Unicode escapes, CRLF line breaks.
        "select array[1,2,3], array [4,5], (array[[1,2],[3,4]])[2][1:2]",
        "select U&'d!0061t'UESCAPE'!', u&'d!0061t' uescape '!'",
        "select a,\r\n b\r\nfrom (select 1 a, 2 b) t\r\nwhere a = 1",
    ]

    private enum Outcome: Equatable {
        case rows([[[String?]]])
        case failure(sqlState: String?, message: String)
    }

    private func outcome(_ session: SQLSession, _ sql: String) async -> Outcome {
        do {
            return .rows(try await run(session, sql))
        } catch let error as PostgresError {
            return .failure(sqlState: error.fields?.sqlState, message: error.message)
        } catch {
            return .failure(sqlState: nil, message: "\(error)")
        }
    }

    @Test(arguments: IT.versions)
    func formattedLookalikesBehaveTheSame(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        for query in Self.lookalikes {
            let formatted = try #require(SQLFormatter.format(query), "\(query)")
            let expected = await outcome(session, query)
            let actual = await outcome(session, formatted)
            #expect(actual == expected, "PostgreSQL \(version): \(query.debugDescription) -> \(formatted.debugDescription)")
            #expect(SQLFormatter.format(formatted) == formatted, "idempotent: \(formatted)")
        }
        await session.close()
        await client.close()
    }

    /// With standard_conforming_strings off a backslash escapes a quote in '…' (`'don\'t   panic'` is one string): the
    /// formatter either refuses or gives text that returns the same rows, whatever the setting.
    @Test(arguments: IT.versions)
    func backslashesMeanTheSameWithEitherStringSetting(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        let queries = ["select 'don\\'t   panic' as s", "select 'C:\\dir' as a,   '\\d+' as b", "select 'x\\' as p,   'y' as q",
                       "select E'it\\'s' as e,   'plain' as p", "select 'a\\\\'   ,  'b'"]
        var refused = 0
        for setting in ["on", "off"] {
            _ = try await run(session, "SET standard_conforming_strings = \(setting)")
            for query in queries {
                guard let formatted = SQLFormatter.format(query) else {
                    refused += 1
                    continue
                }
                let expected = await outcome(session, query)
                let actual = await outcome(session, formatted)
                #expect(actual == expected, "PostgreSQL \(version), standard_conforming_strings \(setting): \(query.debugDescription) -> \(formatted.debugDescription)")
            }
        }
        #expect(SQLFormatter.format(queries[0]) == nil, "the review's case is refused")
        #expect(refused < 2 * queries.count, "most backslashes read the same both ways")
        await session.close()
        await client.close()
    }

    /// Words the formatter may upper- or lower-case anywhere must be reserved by the server itself.
    @Test(arguments: IT.versions)
    func caseChangeableWordsAreReservedByTheServer(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        let rows = try await run(session, "SELECT upper(word) FROM pg_get_keywords() WHERE catcode = 'R'")
        let reserved = Set(rows.flatMap { $0 }.compactMap { $0.first ?? nil })
        #expect(reserved.count >= 77)
        #expect(SQLFormatter.reservedKeywords.isSubset(of: reserved), "not reserved on \(version): \(SQLFormatter.reservedKeywords.subtracting(reserved).sorted())")
        await session.close()
        await client.close()
    }

    private func run(_ session: SQLSession, _ sql: String) async throws -> [[[String?]]] {
        try await session.run(sql, mode: .simple).results.filter(\.hasRowSet).map(\.rows)
    }

    @Test(arguments: IT.versions)
    func formattedQueriesReturnTheSameRows(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        for query in Self.queries {
            let formatted = try #require(SQLFormatter.format(query), "\(query)")
            #expect(formatted != query)
            let expected = try await run(session, query)
            let actual = try await run(session, formatted)
            #expect(actual == expected, "\(formatted)")
            #expect(SQLFormatter.format(formatted) == formatted, "idempotent: \(formatted)")
        }
        await session.close()
        await client.close()
    }

    @Test(arguments: IT.versions)
    func formattedDefinitionsCreateTheSameObjects(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        let suffix = UInt32.random(in: 0...UInt32.max)
        func ddl(_ name: String) -> String {
            "create table shop.\(name) (id bigint not null, name varchar(32) default 'x', total numeric(12, 2), "
                + "primary key (id), check (total >= 0)) partition by range (id)"
        }
        let columns = """
            SELECT column_name, data_type, character_maximum_length, numeric_precision, numeric_scale, is_nullable, column_default
            FROM information_schema.columns WHERE table_schema = 'shop' AND table_name = '%@' ORDER BY ordinal_position
            """
        let plain = "ccinn_fmt_a_\(suffix)"
        let formattedName = "ccinn_fmt_b_\(suffix)"
        let formatted = try #require(SQLFormatter.format(ddl(formattedName)))
        #expect(formatted.contains("\n  id bigint NOT NULL,\n"))
        _ = try await run(session, ddl(plain))
        _ = try await run(session, formatted)
        let expected = try await run(session, columns.replacingOccurrences(of: "%@", with: plain))
        let actual = try await run(session, columns.replacingOccurrences(of: "%@", with: formattedName))
        _ = try await run(session, "DROP TABLE shop.\(plain), shop.\(formattedName)")
        #expect(actual == expected)

        // A function body is a string: formatting never changes what it does.
        let function = "create function shop.ccinn_fmt_f_\(suffix)(a int) returns int language sql as $$ select   a  +1 $$"
        let formattedFunction = try #require(SQLFormatter.format(function))
        _ = try await run(session, formattedFunction)
        let result = try await run(session, "SELECT shop.ccinn_fmt_f_\(suffix)(41)")
        _ = try await run(session, "DROP FUNCTION shop.ccinn_fmt_f_\(suffix)(int)")
        #expect(result == [[["42"]]])

        // MERGE (PostgreSQL 15+): the formatted statement changes the same rows.
        if (Int(version.split(separator: ".").first ?? "0") ?? 0) >= 15 {
            var contents: [[[[String?]]]] = []
            for formats in [false, true] {
                let table = "pg_temp.ccinn_fmt_m\(formats ? 1 : 0)_\(suffix)"
                let merge = "merge into \(table) t using (values (1, 'x'), (2, 'y'), (3, 'z')) as s(id, name) on t.id = s.id "
                    + "when matched and s.name = 'x' then update set name = s.name || '!' when matched then delete "
                    + "when not matched then insert (id, name) values (s.id, s.name)"
                _ = try await run(session, "CREATE TABLE \(table) (id int PRIMARY KEY, name text); INSERT INTO \(table) VALUES (1, 'a'), (2, 'b')")
                _ = try await run(session, formats ? try #require(SQLFormatter.format(merge)) : merge)
                contents.append(try await run(session, "SELECT id, name FROM \(table) ORDER BY id"))
            }
            #expect(contents.first == contents.last)
            #expect(contents.first == [[["1", "x!"], ["3", "z"]]])
        }
        await session.close()
        await client.close()
    }
}
