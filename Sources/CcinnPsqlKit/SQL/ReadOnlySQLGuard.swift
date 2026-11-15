import Foundation

/// Decides whether SQL is a single read-only statement (MCP read-only access, design D12/D14). Token based
/// (strings, dollar quotes, quoted identifiers and comments cannot smuggle keywords) and conservative: anything
/// not clearly a read is rejected. The server enforces the same with a READ ONLY transaction.
public enum ReadOnlySQLGuard {
    /// Keywords that must not appear anywhere in a read-only statement.
    static let forbidden: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "DROP", "CREATE", "ALTER", "GRANT", "REVOKE", "COPY", "CALL",
        "REFRESH", "VACUUM", "CLUSTER", "REINDEX", "LOCK", "NOTIFY", "LISTEN", "UNLISTEN", "PREPARE", "EXECUTE", "DEALLOCATE",
        "DISCARD", "REASSIGN", "SECURITY", "COMMENT", "IMPORT", "CHECKPOINT", "LOAD",
    ]

    /// Functions with side effects outside the transaction, server/file access, or dynamic SQL execution.
    static let forbiddenFunctions: Set<String> = [
        "pg_terminate_backend", "pg_cancel_backend", "pg_reload_conf", "pg_rotate_logfile", "pg_switch_wal", "pg_switch_xlog",
        "pg_create_restore_point", "pg_promote", "pg_wal_replay_pause", "pg_wal_replay_resume", "pg_xlog_replay_pause",
        "pg_xlog_replay_resume", "pg_create_physical_replication_slot", "pg_create_logical_replication_slot",
        "pg_drop_replication_slot", "pg_replication_slot_advance", "pg_copy_physical_replication_slot",
        "pg_copy_logical_replication_slot", "pg_logical_slot_get_changes", "pg_logical_slot_get_binary_changes",
        "pg_logical_emit_message", "set_config", "pg_advisory_lock", "pg_advisory_lock_shared", "pg_advisory_xact_lock",
        "pg_advisory_xact_lock_shared", "pg_try_advisory_lock", "pg_try_advisory_lock_shared", "pg_try_advisory_xact_lock",
        "pg_try_advisory_xact_lock_shared", "pg_advisory_unlock", "pg_advisory_unlock_all", "pg_advisory_unlock_shared",
        "lo_import", "lo_export", "lo_unlink", "lo_create", "lo_creat", "lo_from_bytea", "lo_put", "lo_truncate", "lowrite",
        "pg_read_file", "pg_read_binary_file", "pg_ls_dir", "pg_ls_logdir", "pg_ls_waldir", "pg_ls_tmpdir",
        "pg_ls_archive_statusdir", "pg_ls_logicalsnapdir", "pg_ls_logicalmapdir", "pg_ls_replslotdir", "pg_stat_file",
        "pg_file_write", "pg_file_unlink", "pg_file_rename", "pg_file_sync", "dblink", "dblink_exec", "dblink_connect",
        "dblink_connect_u", "dblink_send_query", "dblink_open", "pg_stat_reset", "pg_stat_reset_shared",
        "pg_stat_reset_single_table_counters", "pg_stat_reset_single_function_counters", "pg_stat_reset_slru",
        "pg_stat_reset_replication_slot", "pg_stat_statements_reset", "nextval", "setval", "pg_notify",
        "pg_backup_start", "pg_backup_stop", "pg_start_backup", "pg_stop_backup", "pg_import_system_collations",
        "query_to_xml", "query_to_xmlschema", "query_to_xml_and_xmlschema", "cursor_to_xml", "cursor_to_xmlschema",
        "pg_log_backend_memory_contexts", "pg_sync_replication_slots",
        // Run a query passed as text (outside the guard's view): core text search and XML, tablefunc, xml2.
        "ts_stat", "ts_rewrite", "crosstab", "crosstab2", "crosstab3", "crosstab4", "connectby", "xpath_table",
    ]

    /// Name prefixes of function families that write, signal, touch server files or execute SQL elsewhere.
    static let forbiddenPrefixes = [
        "pg_replication_origin_", "pg_stat_reset", "pg_create_", "pg_drop_", "pg_file_", "pg_ls_", "pg_read_", "lo_", "dblink",
        "pg_logical_", "pg_wal_replay_", "pg_xlog_replay_", "pg_advisory_", "pg_try_advisory_", "pg_backup_", "pg_switch_",
        // Extensions that run SQL text in other sessions or on other nodes, or take SQL text as input.
        "pg_background_", "run_command_on_", "pgr_",
    ]

    /// How many levels of SQL inside string literals are followed (`f('SELECT g(''…'')')` is two).
    static let maxLiteralDepth = 4

    /// Words that start a statement: literal content beginning with one is SQL and must pass the guard itself.
    /// Includes PL/pgSQL statement starters, since function bodies can arrive as text too.
    static let statementVerbs: Set<String> = [
        "SELECT", "WITH", "VALUES", "TABLE", "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "CREATE", "ALTER", "DROP", "GRANT",
        "REVOKE", "COPY", "CALL", "DO", "EXECUTE", "PREPARE", "DEALLOCATE", "LISTEN", "NOTIFY", "UNLISTEN", "SET", "RESET", "SHOW",
        "BEGIN", "START", "COMMIT", "ROLLBACK", "END", "ABORT", "SAVEPOINT", "RELEASE", "LOCK", "VACUUM", "ANALYZE", "ANALYSE",
        "CLUSTER", "REINDEX", "REFRESH", "DISCARD", "LOAD", "CHECKPOINT", "COMMENT", "SECURITY", "REASSIGN", "IMPORT", "EXPLAIN",
        "DECLARE", "FETCH", "MOVE", "CLOSE", "PERFORM", "RETURN", "RAISE", "IF", "FOR", "LOOP", "WHILE", "FOREACH", "GET",
    ]

    static func isForbiddenFunction(_ name: String) -> Bool {
        forbiddenFunctions.contains(name) || forbiddenPrefixes.contains { name.hasPrefix($0) }
    }

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        check(sql, depth: 0)
    }

    /// `depth`: how many string literals deep `sql` was found (0 for the statement itself).
    private static func check(_ sql: String, depth: Int) -> String? {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let analysis = StatementWords(statement.text)
        let first = analysis.firstWordIndex()
        guard first < analysis.words.count else { return "The statement is empty." }
        switch analysis.words[first] {
        case "SELECT", "WITH", "VALUES", "TABLE":
            return checkQuery(analysis, from: first, depth: depth)
        case "SHOW":
            return nil
        case "EXPLAIN":
            let (_, body) = SQLStatementKind.explainTarget(analysis, at: first)
            let bodyFirst = analysis.firstWordIndex(from: body)
            guard bodyFirst < analysis.words.count, ["SELECT", "WITH", "VALUES", "TABLE"].contains(analysis.words[bodyFirst]) else {
                return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
            }
            return checkQuery(analysis, from: bodyFirst, depth: depth)
        default:
            return rejection(analysis.words[first])
        }
    }

    private static func checkQuery(_ analysis: StatementWords, from start: Int, depth: Int) -> String? {
        guard SQLStatementKind.classify(analysis, from: start) == .query else {
            return "The statement writes data (a data-modifying WITH or SELECT … INTO); it is not allowed in read-only mode."
        }
        if let reason = forbiddenCall(in: analysis) { return reason }
        var parentheses = 0
        for index in start..<analysis.tokens.count {
            let token = analysis.tokens[index]
            if analysis.isPunctuation(index, "(") { parentheses += 1 }
            if analysis.isPunctuation(index, ")") { parentheses = max(0, parentheses - 1) }
            guard token.kind == .keyword || token.kind == .identifier else { continue }
            let word = analysis.words[index]
            if token.kind == .keyword, forbidden.contains(word) { return "`\(word)` is not allowed in a read-only query." }
            if token.kind == .keyword, word == "INTO" { return "SELECT … INTO creates a table; it is not allowed in read-only mode." }
            if token.kind == .keyword, word == "FOR", parentheses == 0,
               analysis.isWord(index + 1, "UPDATE") || analysis.isWord(index + 1, "SHARE") || analysis.isWord(index + 1, "NO")
                || analysis.isWord(index + 1, "KEY") {
                return "Row-locking clauses (FOR UPDATE / FOR SHARE) are not allowed in read-only mode."
            }
        }
        return checkLiterals(in: analysis, depth: depth + 1)
    }

    /// Calls to forbidden functions (also schema-qualified or quoted), Unicode-escaped identifiers and `UESCAPE`,
    /// which could spell any name.
    private static func forbiddenCall(in analysis: StatementWords) -> String? {
        for (index, token) in analysis.tokens.enumerated() {
            guard token.kind == .keyword || token.kind == .identifier || token.kind == .quotedIdentifier else { continue }
            let raw = analysis.lexer.text(of: token)
            if token.kind == .quotedIdentifier, raw.hasPrefix("U&") || raw.hasPrefix("u&") {
                return "Unicode-escaped identifiers (U&\"…\") are not allowed in read-only mode."
            }
            if token.kind != .quotedIdentifier, analysis.words[index] == "UESCAPE" {
                return "UESCAPE is not allowed in read-only mode."
            }
            if analysis.isPunctuation(index + 1, "(") {
                let name = analysis.lexer.identifierValue(of: token)
                if isForbiddenFunction(name) {
                    return "`\(name)()` has side effects outside the query and is not allowed in read-only mode."
                }
            }
        }
        return nil
    }

    /// Many functions run SQL given as text (`ts_stat`, `query_to_xml`, `crosstab`, `pgr_*`, `dblink`, any function that
    /// does `EXECUTE`); a denylist always misses one. So the content of every string literal (adjacent literals joined,
    /// escapes decoded) is read as SQL again: content that starts with a statement verb must pass the whole guard, and
    /// no content may call a forbidden function. Conservative by design: text that merely looks like a write is refused.
    private static func checkLiterals(in analysis: StatementWords, depth: Int) -> String? {
        var index = 0
        while index < analysis.tokens.count {
            guard analysis.tokens[index].kind == .string else {
                index += 1
                continue
            }
            var content = ""
            var isText = false
            while index < analysis.tokens.count, analysis.tokens[index].kind == .string {
                if let part = literalContent(analysis.lexer.text(of: analysis.tokens[index])) {
                    content += part
                    isText = true
                }
                index += 1
            }
            if isText, let reason = checkEmbedded(content, depth: depth) { return reason }
        }
        return nil
    }

    private static func checkEmbedded(_ text: String, depth: Int) -> String? {
        let inner = StatementWords(text)
        guard !inner.tokens.isEmpty else { return nil }
        guard depth <= maxLiteralDepth else { return "SQL is nested too deeply in string literals for a read-only query." }
        let first = inner.firstWordIndex()
        if first < inner.tokens.count, inner.tokens[first].kind == .keyword || inner.tokens[first].kind == .identifier,
           statementVerbs.contains(inner.words[first]) {
            guard let reason = check(text, depth: depth) else { return nil }
            return "A string literal contains SQL that is not allowed in read-only mode: \(reason)"
        }
        if let reason = forbiddenCall(in: inner) { return "A string literal contains SQL that is not allowed in read-only mode: \(reason)" }
        return checkLiterals(in: inner, depth: depth + 1)
    }

    /// The text of a string literal as PostgreSQL reads it (with `standard_conforming_strings = on`, which the
    /// read-only transaction pins): doubled quotes undone, `E''` and `U&''` escapes decoded, dollar quotes stripped.
    /// `nil` for bit strings (`B''`, `X''`), which are not text.
    static func literalContent(_ literal: String) -> String? {
        let text = Substring(literal)
        if text.first == "$" {
            guard let close = text.dropFirst().firstIndex(of: "$") else { return String(text) }
            let tag = text[text.startIndex...close]
            let body = text.dropFirst(tag.count)
            return String(body.hasSuffix(tag) && body.count >= tag.count ? body.dropLast(tag.count) : body)
        }
        guard let open = text.firstIndex(of: "'") else { return String(text) }
        let prefix = text[..<open].uppercased()
        var body = text[text.index(after: open)...]
        if body.last == "'" { body = body.dropLast() }
        switch prefix {
        case "B", "X": return nil
        case "E": return decodeEscapeString(body)
        case "U&": return decodeUnicodeString(body.replacingOccurrences(of: "''", with: "'"))
        default: return body.replacingOccurrences(of: "''", with: "'")
        }
    }

    /// `E'…'`: `\b \f \n \r \t`, octal `\o…`, hex `\xh…`, `\uXXXX`, `\UXXXXXXXX`, `''`, and `\c` for any other `c`.
    static func decodeEscapeString(_ body: Substring) -> String {
        let units = Array(body.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count)
        var index = 0
        func hexValue(_ count: Int, exact: Bool) -> (UInt32, Int)? {
            var value: UInt32 = 0
            var length = 0
            while length < count, index + 1 + length < units.count, let digit = hexDigit(units[index + 1 + length]) {
                value = value * 16 + UInt32(digit)
                length += 1
            }
            return length == 0 || (exact && length != count) ? nil : (value, length)
        }
        while index < units.count {
            let unit = units[index]
            if unit == 0x27, index + 1 < units.count, units[index + 1] == 0x27 {
                bytes.append(0x27)
                index += 2
                continue
            }
            guard unit == 0x5C, index + 1 < units.count else {
                bytes.append(unit)
                index += 1
                continue
            }
            let next = units[index + 1]
            switch next {
            case UInt8(ascii: "b"): bytes.append(0x08); index += 2
            case UInt8(ascii: "f"): bytes.append(0x0C); index += 2
            case UInt8(ascii: "n"): bytes.append(0x0A); index += 2
            case UInt8(ascii: "r"): bytes.append(0x0D); index += 2
            case UInt8(ascii: "t"): bytes.append(0x09); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value: UInt32 = 0
                var length = 0
                while length < 3, index + 1 + length < units.count, (0x30...0x37).contains(units[index + 1 + length]) {
                    value = value * 8 + UInt32(units[index + 1 + length] - 0x30)
                    length += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + length
            case UInt8(ascii: "x"):
                index += 1 // now at `x`
                if let (value, length) = hexValue(2, exact: false) {
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    index += 1 + length
                } else {
                    bytes.append(UInt8(ascii: "x"))
                    index += 1
                }
            case UInt8(ascii: "u"), UInt8(ascii: "U"):
                let count = next == UInt8(ascii: "u") ? 4 : 8
                index += 1 // now at `u`
                if let (value, length) = hexValue(count, exact: true), let scalar = Unicode.Scalar(value) {
                    bytes.append(contentsOf: Array(String(Character(scalar)).utf8))
                    index += 1 + length
                } else {
                    bytes.append(next)
                    index += 1
                }
            default:
                bytes.append(next)
                index += 2
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `U&'…'` with the default escape `\`: `\XXXX`, `\+XXXXXX` (surrogate pairs joined) and `\\`.
    static func decodeUnicodeString(_ body: String) -> String {
        let characters = Array(body.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var pendingHigh: UInt32?
        func hex(_ start: Int, _ count: Int) -> UInt32? {
            guard start + count <= characters.count else { return nil }
            var value: UInt32 = 0
            for scalar in characters[start..<(start + count)] {
                guard scalar.isASCII, let digit = hexDigit(UInt8(scalar.value)) else { return nil }
                value = value * 16 + UInt32(digit)
            }
            return value
        }
        while index < characters.count {
            let scalar = characters[index]
            guard scalar == "\\" else {
                result.append(scalar)
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "\\" {
                result.append("\\")
                index += 2
                continue
            }
            let plus = index + 1 < characters.count && characters[index + 1] == "+"
            guard let value = plus ? hex(index + 2, 6) : hex(index + 1, 4) else {
                result.append(scalar)
                index += 1
                continue
            }
            index += plus ? 8 : 5
            if (0xD800...0xDBFF).contains(value) {
                pendingHigh = value
                continue
            }
            var code = value
            if (0xDC00...0xDFFF).contains(value), let high = pendingHigh {
                code = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
            }
            pendingHigh = nil
            if let decoded = Unicode.Scalar(code) { result.append(decoded) }
        }
        return String(result)
    }

    private static func hexDigit(_ unit: UInt8) -> UInt8? {
        switch unit {
        case 0x30...0x39: unit - 0x30
        case 0x41...0x46: unit - 0x41 + 10
        case 0x61...0x66: unit - 0x61 + 10
        default: nil
        }
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH … SELECT, VALUES, TABLE, SHOW, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write AI access."
    }
}
