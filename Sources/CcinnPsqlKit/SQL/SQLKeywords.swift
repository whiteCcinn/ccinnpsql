import Foundation
import PostgresKit

/// Keyword, type and function vocabulary for PostgreSQL SQL.
public enum SQLKeywords {
    /// Words highlighted as keywords.
    public static let all: Set<String> = Set("""
    ABORT ACCESS ACTION ADD ADMIN AFTER AGGREGATE ALL ALSO ALTER ALWAYS ANALYSE ANALYZE AND ANY ARRAY AS ASC ASYMMETRIC \
    AT ATTACH AUTHORIZATION BEFORE BEGIN BETWEEN BIGINT BIGSERIAL BOOLEAN BOTH BUFFERS BY CACHE CALL CALLED CASCADE CASE CAST \
    CHAR CHARACTER CHECK CHECKPOINT CLOSE CLUSTER COALESCE COLLATE COLLATION COLUMN COMMENT COMMIT COMMITTED CONCURRENTLY \
    CONFLICT CONNECTION CONSTRAINT CONSTRAINTS COPY COSTS CREATE CROSS CSV CUBE CURRENT CURRENT_CATALOG CURRENT_DATE CURRENT_ROLE \
    CURRENT_SCHEMA CURRENT_TIME CURRENT_TIMESTAMP CURRENT_USER CURSOR CYCLE DATA DATABASE DATE DAY DEALLOCATE DECLARE \
    DEFAULT DEFERRABLE DEFERRED DEFINER DELETE DELIMITER DESC DETACH DISABLE DISCARD DISTINCT DO DOMAIN DOUBLE DROP EACH \
    ELSE ENABLE ENCRYPTED END ENUM ESCAPE EXCEPT EXCLUDE EXCLUSIVE EXECUTE EXISTS EXPLAIN EXTENSION EXTRACT FALSE FETCH \
    FILTER FIRST FLOAT FOLLOWING FOR FORCE FOREIGN FORMAT FREEZE FROM FULL FUNCTION FUNCTIONS GENERATED GLOBAL GRANT GRANTED \
    GREATEST GROUP GROUPING GROUPS HANDLER HAVING HOUR IDENTITY IF ILIKE IMMUTABLE IN INCLUDE INCREMENT INDEX INHERIT INHERITS \
    INITIALLY INNER INOUT INSERT INSTEAD INT INTEGER INTERSECT INTERVAL INTO IS ISNULL ISOLATION JOIN JSON JSONB KEY \
    LANGUAGE LARGE LAST LATERAL LEADING LEAST LEFT LEVEL LIKE LIMIT LISTEN LOAD LOCAL LOCALTIME LOCALTIMESTAMP LOCK LOCKED LOGGED MAPPING \
    MATCHED MATERIALIZED MAXVALUE MERGE MINUTE MINVALUE MODE MONTH MOVE NATURAL NEXT NO NONE NOT NOTHING NOTIFY NOTNULL \
    NOWAIT NULL NULLIF NULLS NUMERIC OBJECT OF OFF OFFSET OIDS ON ONLY OPERATOR OPTION OPTIONS OR ORDER ORDINALITY OTHERS OUT \
    OUTER OVER OVERLAPS OVERRIDING OWNED OWNER PARALLEL PARTITION PARTITIONED PASSWORD PLACING POLICY PRECEDING PREPARE \
    PREPARED PRIMARY PRIVILEGES PROCEDURE PROCEDURAL PUBLICATION RANGE READ REAL REASSIGN RECURSIVE REFERENCES REFERENCING \
    REFRESH REINDEX RELEASE RENAME REPEATABLE REPLACE REPLICA RESET RESTART RESTRICT RETURN RETURNING RETURNS REVOKE RIGHT \
    ROLE ROLLBACK ROLLUP ROUTINE ROW ROWS RULE SAVEPOINT SCHEMA SCHEMAS SECOND SECURITY SELECT SEQUENCE SEQUENCES \
    SERIAL SERIALIZABLE SERVER SESSION SESSION_USER SET SETOF SETS SETTINGS SHARE SHOW SIMILAR SKIP SMALLINT SOME STABLE \
    START STATEMENT STATISTICS STDIN STDOUT STORED STRICT SUBSCRIPTION SUMMARY SYMMETRIC SYSTEM TABLE TABLES TABLESAMPLE \
    TABLESPACE TEMP TEMPLATE TEMPORARY TEXT THEN TIES TIME TIMESTAMP TIMING TO TRAILING TRANSACTION TREAT TRIGGER TRIM TRUE \
    TRUNCATE TRUSTED TYPE UNBOUNDED UNCOMMITTED UNIQUE UNION UNKNOWN UNLISTEN UNLOGGED UNTIL UPDATE USER USING VACUUM VALID \
    VALIDATE VALUE VALUES VARCHAR VARIADIC VARYING VERBOSE VIEW VIEWS VOLATILE WAL WHEN WHERE WINDOW WITH WITHIN WITHOUT \
    WORK WRAPPER WRITE XML YEAR YES ZONE
    """.split(separator: " ").map(String.init))

    /// Length of the longest word in `all` (all ASCII).
    static let longestWord = all.map(\.utf16.count).max() ?? 0

    /// Words that must be double-quoted when used as identifiers.
    public static let reserved: Set<String> = Set(SQLText.reservedWords.map { $0.uppercased() })

    /// Keywords that start a statement.
    public static let statementStarters: [String] = [
        "SELECT", "WITH", "VALUES", "TABLE", "EXPLAIN", "EXPLAIN (ANALYZE, BUFFERS)", "SHOW", "SET", "RESET", "INSERT INTO", "UPDATE",
        "DELETE FROM", "MERGE INTO", "TRUNCATE", "COPY", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "CREATE TABLE",
        "CREATE INDEX", "CREATE INDEX CONCURRENTLY", "CREATE VIEW", "CREATE MATERIALIZED VIEW", "CREATE FUNCTION",
        "CREATE PROCEDURE", "CREATE SCHEMA", "CREATE EXTENSION", "CREATE SEQUENCE", "CREATE TYPE", "ALTER TABLE", "ALTER INDEX",
        "DROP TABLE", "DROP INDEX", "REFRESH MATERIALIZED VIEW", "REFRESH MATERIALIZED VIEW CONCURRENTLY", "VACUUM",
        "VACUUM (VERBOSE, ANALYZE)", "ANALYZE", "REINDEX", "CLUSTER", "CALL", "DO", "LISTEN", "NOTIFY", "UNLISTEN",
        "GRANT", "REVOKE", "COMMENT ON", "LOCK TABLE", "DISCARD ALL",
    ]

    /// Targets offered after `SHOW`.
    public static let showTargets: [String] = [
        "ALL", "search_path", "server_version", "work_mem", "shared_buffers", "max_connections", "statement_timeout",
        "lock_timeout", "idle_in_transaction_session_timeout", "TimeZone", "DateStyle", "default_transaction_isolation",
        "transaction_isolation", "effective_cache_size", "maintenance_work_mem", "random_page_cost", "wal_level",
    ]

    /// Clause keywords offered inside a query.
    public static let clauseKeywords: [String] = [
        "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY", "LIMIT", "OFFSET", "FETCH FIRST", "JOIN", "LEFT JOIN", "RIGHT JOIN",
        "INNER JOIN", "FULL OUTER JOIN", "CROSS JOIN", "LATERAL", "ON", "USING", "AS", "AND", "OR", "NOT", "IN", "IS NULL",
        "IS NOT NULL", "IS DISTINCT FROM", "LIKE", "ILIKE", "SIMILAR TO", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END",
        "DISTINCT", "DISTINCT ON", "UNION ALL", "UNION", "INTERSECT", "EXCEPT", "EXISTS", "ANY", "ALL", "OVER", "PARTITION BY",
        "WINDOW", "FILTER", "WITHIN GROUP", "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "INTERVAL", "RETURNING",
        "ON CONFLICT", "DO NOTHING", "DO UPDATE SET", "FOR UPDATE", "FOR SHARE", "SKIP LOCKED", "TABLESAMPLE", "WITH ORDINALITY",
    ]

    /// Common type names (completion after `::` and in DDL).
    public static let types: [String] = [
        "bigint", "bigserial", "boolean", "bytea", "char", "character varying", "cidr", "date", "double precision", "inet",
        "integer", "interval", "json", "jsonb", "macaddr", "money", "numeric", "real", "serial", "smallint", "text", "time",
        "timestamp", "timestamptz", "timetz", "tsquery", "tsvector", "uuid", "varchar", "xml", "int4range", "int8range",
        "numrange", "tsrange", "tstzrange", "daterange", "regclass", "oid", "name", "pg_lsn",
    ]
}

/// PostgreSQL built-in functions offered by completion (name and signature).
public enum SQLFunctions {
    public struct Function: Sendable, Hashable {
        public let name: String
        public let signature: String
    }

    public static let all: [Function] = [
        ("count", "count(expr) → bigint"), ("sum", "sum(expr)"), ("avg", "avg(expr)"), ("min", "min(expr)"), ("max", "max(expr)"),
        ("array_agg", "array_agg(expr ORDER BY …)"), ("string_agg", "string_agg(text, delimiter)"), ("json_agg", "json_agg(expr)"),
        ("jsonb_agg", "jsonb_agg(expr)"), ("jsonb_object_agg", "jsonb_object_agg(key, value)"), ("bool_and", "bool_and(bool)"),
        ("bool_or", "bool_or(bool)"), ("percentile_cont", "percentile_cont(fraction) WITHIN GROUP (ORDER BY …)"),
        ("percentile_disc", "percentile_disc(fraction) WITHIN GROUP (ORDER BY …)"), ("mode", "mode() WITHIN GROUP (ORDER BY …)"),
        ("stddev", "stddev(expr)"), ("variance", "variance(expr)"), ("row_number", "row_number() OVER (…)"), ("rank", "rank() OVER (…)"),
        ("dense_rank", "dense_rank() OVER (…)"), ("lag", "lag(expr [, offset [, default]]) OVER (…)"),
        ("lead", "lead(expr [, offset [, default]]) OVER (…)"), ("first_value", "first_value(expr) OVER (…)"),
        ("last_value", "last_value(expr) OVER (…)"), ("ntile", "ntile(n) OVER (…)"), ("coalesce", "coalesce(a, b, …)"),
        ("nullif", "nullif(a, b)"), ("greatest", "greatest(a, b, …)"), ("least", "least(a, b, …)"), ("now", "now() → timestamptz"),
        ("current_date", "current_date"), ("clock_timestamp", "clock_timestamp()"), ("date_trunc", "date_trunc(field, source)"),
        ("date_part", "date_part(field, source)"), ("extract", "extract(field FROM source)"), ("age", "age(timestamp [, timestamp])"),
        ("make_interval", "make_interval(years, months, …)"), ("to_char", "to_char(value, format)"), ("to_date", "to_date(text, format)"),
        ("to_timestamp", "to_timestamp(double | text, format)"), ("generate_series", "generate_series(start, stop [, step])"),
        ("length", "length(text)"), ("lower", "lower(text)"), ("upper", "upper(text)"), ("trim", "trim(text)"),
        ("substring", "substring(text FROM … FOR …)"), ("split_part", "split_part(text, delimiter, n)"), ("concat", "concat(…)"),
        ("concat_ws", "concat_ws(sep, …)"), ("format", "format(fmt, …)"), ("replace", "replace(text, from, to)"),
        ("regexp_replace", "regexp_replace(text, pattern, replacement [, flags])"), ("regexp_matches", "regexp_matches(text, pattern)"),
        ("left", "left(text, n)"), ("right", "right(text, n)"), ("position", "position(sub IN text)"), ("md5", "md5(text)"),
        ("gen_random_uuid", "gen_random_uuid() → uuid"), ("random", "random()"), ("round", "round(numeric [, digits])"),
        ("ceil", "ceil(numeric)"), ("floor", "floor(numeric)"), ("abs", "abs(x)"), ("unnest", "unnest(array)"),
        ("array_length", "array_length(array, dim)"), ("cardinality", "cardinality(array)"), ("array_to_string", "array_to_string(array, sep)"),
        ("jsonb_build_object", "jsonb_build_object(k, v, …)"), ("jsonb_set", "jsonb_set(target, path, value)"),
        ("jsonb_array_elements", "jsonb_array_elements(jsonb)"), ("jsonb_each", "jsonb_each(jsonb)"), ("jsonb_path_query", "jsonb_path_query(jsonb, path)"),
        ("to_jsonb", "to_jsonb(value)"), ("row_to_json", "row_to_json(record)"), ("pg_size_pretty", "pg_size_pretty(bigint)"),
        ("pg_total_relation_size", "pg_total_relation_size(regclass)"), ("pg_relation_size", "pg_relation_size(regclass)"),
        ("pg_database_size", "pg_database_size(name)"), ("pg_backend_pid", "pg_backend_pid()"), ("pg_sleep", "pg_sleep(seconds)"),
        ("current_setting", "current_setting(name)"), ("pg_typeof", "pg_typeof(any)"), ("version", "version()"),
        ("pg_blocking_pids", "pg_blocking_pids(pid)"), ("pg_cancel_backend", "pg_cancel_backend(pid)"),
        ("pg_terminate_backend", "pg_terminate_backend(pid)"), ("pg_get_viewdef", "pg_get_viewdef(regclass)"),
        ("pg_get_functiondef", "pg_get_functiondef(oid)"), ("to_tsvector", "to_tsvector([config,] text)"),
        ("to_tsquery", "to_tsquery([config,] text)"), ("ts_rank", "ts_rank(tsvector, tsquery)"),
    ].map { Function(name: $0.0, signature: $0.1) }

    /// Upper-cased names, for highlighting calls.
    public static let names: Set<String> = Set(all.map { $0.name.uppercased() })
}
