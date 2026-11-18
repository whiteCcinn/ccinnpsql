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
            // Built field by field: one large mixed literal exceeds older compilers' type-checking budget (Swift 6.2).
            var fields: [String: JSONValue] = [:]
            fields["name"] = .string(name)
            fields["setting"] = JSONValue(row.string("setting"))
            fields["unit"] = JSONValue(row.text("unit"))
            fields["category"] = JSONValue(row.text("category"))
            fields["short_desc"] = JSONValue(row.text("short_desc"))
            fields["source"] = JSONValue(row.text("source"))
            fields["pending_restart"] = .bool(row.bool("pending_restart") ?? false)
            return .object(fields.filter { $0.value != .null })
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
            var fields: [String: JSONValue] = [:]
            fields["name"] = .string(name)
            fields["superuser"] = .bool(row.bool("rolsuper") ?? false)
            fields["inherit"] = .bool(row.bool("rolinherit") ?? true)
            fields["create_role"] = .bool(row.bool("rolcreaterole") ?? false)
            fields["create_db"] = .bool(row.bool("rolcreatedb") ?? false)
            fields["can_login"] = .bool(row.bool("rolcanlogin") ?? false)
            fields["replication"] = .bool(row.bool("rolreplication") ?? false)
            fields["bypass_rls"] = .bool(row.bool("rolbypassrls") ?? false)
            fields["connection_limit"] = JSONValue(row.int("rolconnlimit"))
            let memberOf: [JSONValue] = row.array("member_of").map { JSONValue.string($0) }
            fields["member_of"] = .array(memberOf)
            return .object(fields.filter { $0.value != .null })
        }
        return ["roles": .array(Array(roles.prefix(maxRoles))), "count": .int(Int64(roles.count)), "truncated": .bool(roles.count > maxRoles)]
    }
}
