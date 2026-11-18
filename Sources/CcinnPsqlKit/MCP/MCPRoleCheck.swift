import Foundation
import PostgresKit

/// Whether read-only AI access may run on a connection whose role is privileged.
public enum MCPRolePolicy: Sendable, Equatable {
    /// The default: a privileged role is refused.
    case refusePrivileged
    /// The connection's "Allow AI read-only access on a privileged role" setting is on.
    case allowPrivileged
}

/// What a read-only MCP call learns about its session before it runs anything else: run on the call's own connection,
/// inside its READ ONLY transaction, immediately before the statement (and before every metadata tool).
///
/// No SQL-text check can stop a privileged role: any function, or SQL built at run time (`'CO' || 'PY …'`), can run
/// `COPY … TO / FROM PROGRAM`, read and write server files, or read whatever its privileges show (every session's SQL with
/// pg_read_all_stats, superuser-only settings such as `primary_conninfo` with pg_read_all_settings), and READ ONLY does not
/// block that. So the role itself is the control: a session whose current or session user reaches, through any chain of
/// memberships (INHERIT and SET ignored), a superuser or one of `privilegedBuiltInRoles` is refused unless the connection
/// allows it. SECURITY DEFINER functions and procedures owned by such roles that the session may execute, and foreign
/// tables it may read whose options run a server program or read a server file (file_fdw `program` / `filename`), are
/// reported, not refused (extensions ship the first; reading the second runs what its creator chose, and nothing in the SQL
/// text shows it).
public struct MCPRoleCheck: Sendable, Equatable {
    /// The privileged roles the session reaches (superusers, and `privilegedBuiltInRoles`), by name.
    public var privilegedRoles: [String]
    /// SECURITY DEFINER functions and procedures owned by a privileged role (or one of its members) that the session may
    /// execute, in the database the call uses.
    public var securityDefinerCount: Int
    /// The first of them (`schema.name(argument types)`), at most `listedDefiners`.
    public var securityDefiners: [String]
    /// The session's `client_encoding`: anything but UTF8 would make the server read the text differently from the guard.
    public var clientEncoding: String
    /// Foreign tables the session may read (any column) whose table, server or wrapper options include `program` or
    /// `filename` (file_fdw, or any wrapper with such options), in the database the call uses.
    public var fileTableCount: Int
    /// The first of them (`schema.name`), at most `listedDefiners`.
    public var fileTables: [String]
    /// The session's effective search path (`current_schemas(true)`), read before the check pins search_path: the schemas
    /// an unqualified name in the AI's statement resolves against.
    public var searchPathSchemas: [String]
    /// The database's encoding, and its longest character in bytes (1 for LATIN*, WIN125*, SQL_ASCII, …).
    public var serverEncoding: String
    public var encodingMaxLength: Int
    /// Functions and procedures in untrusted languages (internal, C, plpython3u, plperlu, …) the session may execute, outside
    /// pg_catalog, information_schema and `reviewedExtensions`: how many, the first of them (`schema.name(argument types)`),
    /// and every name (refused when called by name).
    public var untrustedCount: Int
    public var untrustedFunctions: [String]
    public var untrustedNames: [String]
    /// Readable foreign tables of wrappers other than file_fdw (postgres_fdw, …), not already in `fileTables`.
    public var foreignTableCount: Int
    public var foreignTables: [String]

    /// How many SECURITY DEFINER routines and file-reading foreign tables are named in a notice.
    public static let listedDefiners = 20
    /// Built-in roles that run server programs, touch server files, or read every session's SQL and every setting
    /// (pg_monitor contains pg_read_all_stats and pg_read_all_settings; the membership walk would find them anyway).
    public static let privilegedBuiltInRoles = ["pg_execute_server_program", "pg_read_server_files", "pg_write_server_files",
                                                "pg_read_all_stats", "pg_read_all_settings", "pg_monitor"]
    private static let privilegedList = privilegedBuiltInRoles.map { "'\($0)'" }.joined(separator: ", ")

    /// Extensions whose functions were reviewed: none reads or writes outside the database, reaches other sessions' data or
    /// runs SQL given as text. Deliberately not here: pg_stat_statements (its function returns every user's queries),
    /// pageinspect, pgstattuple, pg_buffercache, dblink, postgres_fdw, file_fdw, tablefunc, adminpack, pg_net, http. An
    /// integration test requires every extension the tested images ship to be reviewed here or listed as not reviewed.
    public static let reviewedExtensions = ["plpgsql", "pg_trgm", "btree_gin", "btree_gist", "citext", "hstore", "cube", "earthdistance",
                                            "fuzzystrmatch", "intarray", "isn", "ltree", "seg", "unaccent", "uuid-ossp", "pgcrypto", "vector",
                                            "postgis", "postgis_raster", "postgis_topology"]
    static let reviewedExtensionsSQL = reviewedExtensions.map { "'\($0)'" }.joined(separator: ", ")

    /// Run first, with the session's own search_path (its only name is qualified).
    public static let searchPathQuery = "SELECT pg_catalog.current_schemas(true)::pg_catalog.text[] AS search_schemas"

    /// The catalog query, in plain ASCII (it runs in databases of every encoding). Every name is qualified with `pg_catalog`,
    /// and the caller pins `search_path` to
    /// `pg_catalog, pg_temp` around it, so neither a role's search_path nor a temporary table can shadow a catalog
    /// object, function or operator.
    public static let query = """
        WITH RECURSIVE privileged(oid) AS (
            SELECT r.oid FROM pg_catalog.pg_roles r
             WHERE r.rolsuper OR r.rolname IN (\(privilegedList))
            UNION
            SELECT m.member FROM pg_catalog.pg_auth_members m JOIN privileged p ON m.roleid = p.oid
        ), reached(oid) AS (
            SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname IN (current_user, session_user)
            UNION
            SELECT m.roleid FROM pg_catalog.pg_auth_members m JOIN reached s ON m.member = s.oid
        ), definers AS (
            SELECT f.oid FROM pg_catalog.pg_proc f
             WHERE f.prosecdef AND f.proowner IN (SELECT oid FROM privileged)
               AND pg_catalog.has_function_privilege(f.oid, 'EXECUTE')
        ), file_tables AS (
            SELECT t.ftrelid FROM pg_catalog.pg_foreign_table t
              JOIN pg_catalog.pg_foreign_server s ON s.oid = t.ftserver
              JOIN pg_catalog.pg_foreign_data_wrapper w ON w.oid = s.srvfdw
             WHERE pg_catalog.has_any_column_privilege(t.ftrelid, 'SELECT')
               AND EXISTS (SELECT 1 FROM pg_catalog.unnest(pg_catalog.array_cat(pg_catalog.array_cat(t.ftoptions, s.srvoptions), w.fdwoptions)) o(option)
                            WHERE pg_catalog.lower(pg_catalog.split_part(o.option, '=', 1)) IN ('program', 'filename'))
        ), untrusted AS (
            -- Aggregates and the constructors CREATE TYPE ... AS RANGE makes are language internal too; they run nothing of their own.
            SELECT f.oid, f.proname FROM pg_catalog.pg_proc f
              JOIN pg_catalog.pg_language l ON l.oid = f.prolang
              JOIN pg_catalog.pg_namespace n ON n.oid = f.pronamespace
             WHERE NOT l.lanpltrusted AND f.prokind <> 'a'
               AND n.nspname NOT IN ('pg_catalog', 'information_schema')
               AND pg_catalog.has_function_privilege(f.oid, 'EXECUTE')
               AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                                WHERE d.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND d.objid = f.oid
                                  AND ((d.deptype = 'e' AND d.refclassid = 'pg_catalog.pg_extension'::pg_catalog.regclass
                                        AND d.refobjid IN (SELECT e.oid FROM pg_catalog.pg_extension e WHERE e.extname IN (\(reviewedExtensionsSQL))))
                                    OR (d.deptype = 'i' AND d.refclassid = 'pg_catalog.pg_type'::pg_catalog.regclass)))
        ), other_foreign AS (
            SELECT t.ftrelid FROM pg_catalog.pg_foreign_table t
              JOIN pg_catalog.pg_foreign_server s ON s.oid = t.ftserver
              JOIN pg_catalog.pg_foreign_data_wrapper w ON w.oid = s.srvfdw
             WHERE w.fdwname <> 'file_fdw' AND pg_catalog.has_any_column_privilege(t.ftrelid, 'SELECT')
               AND t.ftrelid NOT IN (SELECT ft.ftrelid FROM file_tables ft)
        )
        SELECT
            ARRAY(SELECT r.rolname::pg_catalog.text FROM reached s JOIN pg_catalog.pg_roles r ON r.oid = s.oid
                   WHERE r.rolsuper OR r.rolname IN (\(privilegedList))
                   ORDER BY 1) AS privileged_roles,
            (SELECT pg_catalog.count(*) FROM definers) AS definer_count,
            ARRAY(SELECT d.oid::pg_catalog.regprocedure::pg_catalog.text FROM definers d ORDER BY 1 LIMIT \(listedDefiners)) AS definers,
            pg_catalog.current_setting('client_encoding') AS client_encoding,
            (SELECT pg_catalog.count(*) FROM file_tables) AS file_table_count,
            ARRAY(SELECT f.ftrelid::pg_catalog.regclass::pg_catalog.text FROM file_tables f ORDER BY 1 LIMIT \(listedDefiners)) AS file_tables,
            pg_catalog.current_setting('server_encoding') AS server_encoding,
            (SELECT pg_catalog.pg_encoding_max_length(d.encoding) FROM pg_catalog.pg_database d
              WHERE d.datname = pg_catalog.current_database()) AS encoding_max_length,
            (SELECT pg_catalog.count(*) FROM untrusted) AS untrusted_count,
            ARRAY(SELECT u.oid::pg_catalog.regprocedure::pg_catalog.text FROM untrusted u ORDER BY 1 LIMIT \(listedDefiners)) AS untrusted,
            ARRAY(SELECT DISTINCT u.proname::pg_catalog.text FROM untrusted u ORDER BY 1) AS untrusted_names,
            (SELECT pg_catalog.count(*) FROM other_foreign) AS foreign_table_count,
            ARRAY(SELECT o.ftrelid::pg_catalog.regclass::pg_catalog.text FROM other_foreign o ORDER BY 1 LIMIT \(listedDefiners)) AS foreign_tables
        """

    public init(privilegedRoles: [String], securityDefinerCount: Int, securityDefiners: [String], clientEncoding: String,
                fileTableCount: Int = 0, fileTables: [String] = [], searchPathSchemas: [String] = [], serverEncoding: String = "UTF8",
                encodingMaxLength: Int = 4, untrustedCount: Int = 0, untrustedFunctions: [String] = [], untrustedNames: [String] = [],
                foreignTableCount: Int = 0, foreignTables: [String] = []) {
        self.privilegedRoles = privilegedRoles
        self.securityDefinerCount = securityDefinerCount
        self.securityDefiners = securityDefiners
        self.clientEncoding = clientEncoding
        self.fileTableCount = fileTableCount
        self.fileTables = fileTables
        self.searchPathSchemas = searchPathSchemas
        self.serverEncoding = serverEncoding
        self.encodingMaxLength = encodingMaxLength
        self.untrustedCount = untrustedCount
        self.untrustedFunctions = untrustedFunctions
        self.untrustedNames = untrustedNames
        self.foreignTableCount = foreignTableCount
        self.foreignTables = foreignTables
    }

    /// Reads the answers to `query` and `searchPathQuery`. Anything else fails closed: the call is refused.
    public init(_ answer: ResultSet, searchPath: ResultSet) throws {
        guard answer.rows.count == 1, let row = answer.first, searchPath.rows.count == 1, let schemas = searchPath.first?.raw("search_schemas"),
              let roles = row.raw("privileged_roles"), let count = row.raw("definer_count").flatMap({ Int($0) }),
              let definers = row.raw("definers"), let encoding = row.raw("client_encoding"),
              let fileTableCount = row.raw("file_table_count").flatMap({ Int($0) }), let fileTables = row.raw("file_tables"),
              let serverEncoding = row.raw("server_encoding"), let encodingMaxLength = row.raw("encoding_max_length").flatMap({ Int($0) }),
              let untrustedCount = row.raw("untrusted_count").flatMap({ Int($0) }), let untrusted = row.raw("untrusted"),
              let untrustedNames = row.raw("untrusted_names"), let foreignTableCount = row.raw("foreign_table_count").flatMap({ Int($0) }),
              let foreignTables = row.raw("foreign_tables") else {
            throw MCPToolError("Could not check this connection's role, so read-only AI access is refused.")
        }
        self.init(privilegedRoles: PostgresArray.parse(roles), securityDefinerCount: count, securityDefiners: PostgresArray.parse(definers),
                  clientEncoding: encoding, fileTableCount: fileTableCount, fileTables: PostgresArray.parse(fileTables),
                  searchPathSchemas: PostgresArray.parse(schemas), serverEncoding: serverEncoding, encodingMaxLength: encodingMaxLength,
                  untrustedCount: untrustedCount, untrustedFunctions: PostgresArray.parse(untrusted), untrustedNames: PostgresArray.parse(untrustedNames),
                  foreignTableCount: foreignTableCount, foreignTables: PostgresArray.parse(foreignTables))
    }

    public var isPrivileged: Bool { !privilegedRoles.isEmpty }

    /// The encoding's name when it is single-byte: the server then folds non-ASCII letters in unquoted names by locale.
    public var singleByteEncoding: String? { encodingMaxLength <= 1 ? serverEncoding : nil }

    /// Why the statement may not run in this session (the guard again, on exactly the text sent, now that the database's
    /// encoding is known), or `nil`.
    public func refusal(forStatement sql: String) -> String? {
        ReadOnlySQLGuard.check(sql, singleByteEncoding: singleByteEncoding, untrustedFunctions: Set(untrustedNames))
    }

    /// Forbidden schemas on the search path (orafce's `dbms_sql`, `dbms_pipe`, `dbms_alert`, `utl_file`): their functions
    /// have generic names (`open_cursor()`, `fopen()`), so an unqualified call reaches them past the text check.
    public var forbiddenSearchPathSchemas: [String] {
        searchPathSchemas.filter { ReadOnlySQLGuard.forbiddenSchemas.contains($0.lowercased()) }
    }

    /// Why the call is refused under `policy`, or `nil` when it may run.
    public func refusal(_ policy: MCPRolePolicy) -> String? {
        guard clientEncoding.uppercased() == "UTF8" else {
            return "This session's client_encoding is \(clientEncoding), not UTF8, so the server could read the SQL differently from "
                + "the read-only check; read-only AI access is refused."
        }
        if let schema = forbiddenSearchPathSchemas.first {
            return "search_path includes \(schema); AI read-only mode refuses this connection: functions there run SQL given as text or "
                + "act outside the transaction, and an unqualified call reaches them. Remove it from the role's or database's search_path."
        }
        guard isPrivileged, policy == .refusePrivileged else { return nil }
        return "This connection's role can run server programs, touch server files or read every session's SQL and settings, "
            + "which a read-only check can't prevent. "
            + "Connect with a less privileged role, or allow it for this connection in AI settings. "
            + "(It reaches: \(privilegedRoles.joined(separator: ", ")).)"
    }

    /// What a call says about its session (whether it succeeds or fails): a privileged role allowed for this connection,
    /// SECURITY DEFINER helpers the read-only check cannot see inside, and foreign tables that run a program or read a server
    /// file when read.
    public func notices(_ policy: MCPRolePolicy) -> [String] {
        var notices: [String] = []
        if isPrivileged, policy == .allowPrivileged {
            notices.append("This connection's role reaches \(privilegedRoles.joined(separator: ", ")); read-only AI access on it is "
                + "allowed for this connection in AI settings, so the read-only check can't prevent server programs, file access or "
                + "reading other sessions' SQL.")
        }
        if securityDefinerCount > 0 {
            notices.append("\(securityDefinerCount) SECURITY DEFINER functions owned by privileged roles are callable; the read-only "
                + "check can't see inside them: \(Self.listing(securityDefiners, of: securityDefinerCount))")
        }
        if fileTableCount > 0 {
            notices.append("\(fileTableCount) readable foreign tables run a server program or read a server file when read (file_fdw "
                + "program / filename options); the read-only check can't prevent that: \(Self.listing(fileTables, of: fileTableCount))")
        }
        if untrustedCount > 0 {
            notices.append("\(untrustedCount) callable functions in untrusted languages (internal, C, plpython3u, …) outside pg_catalog and "
                + "reviewed extensions run with the server's access; the read-only check can't see inside them and refuses direct calls to "
                + "them, but views, operators, casts, defaults and row security can still call them (revoke EXECUTE to stop that): "
                + Self.listing(untrustedFunctions, of: untrustedCount))
        }
        if foreignTableCount > 0 {
            notices.append("\(foreignTableCount) readable foreign tables of other wrappers (postgres_fdw, …) read a fixed remote destination "
                + "when read: \(Self.listing(foreignTables, of: foreignTableCount))")
        }
        return notices
    }

    /// `names` (at most `listedDefiners`), with `…` when `count` says there are more.
    public static func listing(_ names: [String], of count: Int) -> String {
        let listed = names.prefix(listedDefiners)
        return listed.joined(separator: ", ") + (count > listed.count ? ", …" : "")
    }
}
