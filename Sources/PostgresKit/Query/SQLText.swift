import Foundation

/// Safe construction of identifiers and literals for statements the app builds itself. Prefer bound
/// parameters (`$1`); use these where PostgreSQL does not accept parameters (identifiers, utility commands).
public enum SQLText {
    /// Double-quoted identifier; embedded quotes are doubled. Nothing else changes: a NUL stays, and the transport refuses
    /// the statement (removing it would name a different object than the one asked for).
    public static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Identifier quoted only when needed (lower-case letters, digits, `_`, `$`, not starting with a digit or `$`, not a reserved word).
    public static func identifier(_ name: String) -> String {
        guard let first = name.unicodeScalars.first, first == "_" || ("a"..."z").contains(first),
              name.unicodeScalars.allSatisfy({ $0 == "_" || $0 == "$" || ("a"..."z").contains($0) || ("0"..."9").contains($0) }),
              !reservedWords.contains(name) else {
            return quoteIdentifier(name)
        }
        return name
    }

    /// `schema.name` with each part quoted as needed.
    public static func qualified(_ schema: String?, _ name: String) -> String {
        guard let schema, !schema.isEmpty else { return identifier(name) }
        return identifier(schema) + "." + identifier(name)
    }

    /// Standard-conforming string literal (`'it''s'`). A NUL stays, and the transport refuses the statement (PostgreSQL text
    /// cannot hold one, and dropping it would send a different value).
    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Reserved key words that always need quoting as identifiers (PostgreSQL `RESERVED_KEYWORD` list).
    public static let reservedWords: Set<String> = [
        "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "asymmetric", "authorization", "binary", "both", "case",
        "cast", "check", "collate", "collation", "column", "concurrently", "constraint", "create", "cross", "current_catalog",
        "current_date", "current_role", "current_schema", "current_time", "current_timestamp", "current_user", "default",
        "deferrable", "desc", "distinct", "do", "else", "end", "except", "false", "fetch", "for", "foreign", "freeze", "from",
        "full", "grant", "group", "having", "ilike", "in", "initially", "inner", "intersect", "into", "is", "isnull", "join",
        "lateral", "leading", "left", "like", "limit", "localtime", "localtimestamp", "natural", "not", "notnull", "null",
        "offset", "on", "only", "or", "order", "outer", "overlaps", "placing", "primary", "references", "returning", "right",
        "select", "session_user", "similar", "some", "symmetric", "system_user", "table", "tablesample", "then", "to",
        "trailing", "true", "union", "unique", "user", "using", "variadic", "verbose", "when", "where", "window", "with",
    ]
}
