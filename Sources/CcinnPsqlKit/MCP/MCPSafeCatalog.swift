import Foundation
import PostgresKit

/// Server settings and roles as the AI may see them (`get_settings`, `list_roles`). Read-only `run_query` refuses
/// `pg_settings`, `pg_roles` and `pg_user`: custom parameters and role settings can hold secrets
/// (`ALTER ROLE app SET myapp.api_key = '…'`), and a text check cannot tell `SELECT *` or a `LIKE` filter from a harmless
/// lookup. These tools select fixed columns, and their encoders keep an allowlist on top of the query, so neither a custom
/// (dotted) parameter nor `rolconfig`, `rolpassword` or `rolvaliduntil` ever reaches the AI, whatever the query returned.
enum MCPSafeCatalog {
    /// Built-in parameters (every custom parameter's name has a dot), without `sourcefile` / `sourceline` (server paths).
    static let settingsQuery = """
        SELECT s.name, s.setting, s.unit, s.category, s.short_desc, s.source, s.pending_restart
          FROM pg_catalog.pg_settings s
         WHERE pg_catalog.strpos(s.name, '.') = 0
         ORDER BY s.name
        """

    /// Role names, attributes and memberships, by named columns of `pg_roles` (never its settings, password or expiry, nor
    /// role comments, which are free text).
    static let rolesQuery = """
        SELECT r.rolname, r.rolsuper, r.rolinherit, r.rolcreaterole, r.rolcreatedb, r.rolcanlogin, r.rolreplication, r.rolbypassrls, r.rolconnlimit,
               ARRAY(SELECT b.rolname::pg_catalog.text FROM pg_catalog.pg_auth_members m JOIN pg_catalog.pg_roles b ON b.oid = m.roleid
                      WHERE m.member = r.oid ORDER BY 1) AS member_of
          FROM pg_catalog.pg_roles r
         ORDER BY r.rolname
        """

    static let maxRoles = 1_000

    /// The built-in parameters among `records` whose name contains `filter` (case-insensitive; matched here, never sent as
    /// SQL), with the allowed fields only.
    static func settings(_ records: [Record], filter: String?) -> JSONValue {
        let needle = filter?.lowercased()
        let settings = records.compactMap { row -> JSONValue? in
            guard let name = row.raw("name"), isBuiltIn(name), needle.map({ name.lowercased().contains($0) }) ?? true else { return nil }
            return .object([
                "name": .string(name), "setting": JSONValue(row.string("setting")), "unit": JSONValue(row.text("unit")),
                "category": JSONValue(row.text("category")), "short_desc": JSONValue(row.text("short_desc")),
                "source": JSONValue(row.text("source")), "pending_restart": .bool(row.bool("pending_restart") ?? false),
            ].filter { $0.value != .null })
        }
        return ["settings": .array(settings), "count": .int(Int64(settings.count)),
                "note": "Built-in parameters only: custom parameters (names with a dot) can hold secrets and are never listed."]
    }

    /// Every custom parameter's name has a dot (`myapp.api_key`, `pg_stat_statements.max`).
    static func isBuiltIn(_ name: String) -> Bool { !name.contains(".") }

    /// Roles with the allowed fields only.
    static func roles(_ records: [Record]) -> JSONValue {
        let roles = records.compactMap { row -> JSONValue? in
            guard let name = row.raw("rolname") else { return nil }
            return .object([
                "name": .string(name), "superuser": .bool(row.bool("rolsuper") ?? false), "inherit": .bool(row.bool("rolinherit") ?? true),
                "create_role": .bool(row.bool("rolcreaterole") ?? false),
                "create_db": .bool(row.bool("rolcreatedb") ?? false), "can_login": .bool(row.bool("rolcanlogin") ?? false),
                "replication": .bool(row.bool("rolreplication") ?? false), "bypass_rls": .bool(row.bool("rolbypassrls") ?? false),
                "connection_limit": JSONValue(row.int("rolconnlimit")), "member_of": .array(row.array("member_of").map { .string($0) }),
            ].filter { $0.value != .null })
        }
        return ["roles": .array(Array(roles.prefix(maxRoles))), "count": .int(Int64(roles.count)), "truncated": .bool(roles.count > maxRoles)]
    }
}
