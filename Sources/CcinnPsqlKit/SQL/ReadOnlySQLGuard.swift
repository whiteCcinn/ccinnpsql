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
    ]

    /// `nil` when allowed; otherwise the reason it is rejected.
    public static func check(_ sql: String) -> String? {
        let statements = SQLStatementSplitter.split(sql)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        let analysis = StatementWords(statement.text)
        let first = analysis.firstWordIndex()
        guard first < analysis.words.count else { return "The statement is empty." }
        switch analysis.words[first] {
        case "SELECT", "WITH", "VALUES", "TABLE":
            return checkQuery(analysis, from: first)
        case "SHOW":
            return nil
        case "EXPLAIN":
            let (_, body) = SQLStatementKind.explainTarget(analysis, at: first)
            let bodyFirst = analysis.firstWordIndex(from: body)
            guard bodyFirst < analysis.words.count, ["SELECT", "WITH", "VALUES", "TABLE"].contains(analysis.words[bodyFirst]) else {
                return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
            }
            return checkQuery(analysis, from: bodyFirst)
        default:
            return rejection(analysis.words[first])
        }
    }

    private static func checkQuery(_ analysis: StatementWords, from start: Int) -> String? {
        guard SQLStatementKind.classify(analysis, from: start) == .query else {
            return "The statement writes data (a data-modifying WITH or SELECT … INTO); it is not allowed in read-only mode."
        }
        var depth = 0
        for index in start..<analysis.tokens.count {
            let token = analysis.tokens[index]
            if analysis.isPunctuation(index, "(") { depth += 1 }
            if analysis.isPunctuation(index, ")") { depth = max(0, depth - 1) }
            guard token.kind == .keyword || token.kind == .identifier || token.kind == .quotedIdentifier else { continue }
            let word = analysis.words[index]
            if token.kind == .keyword, forbidden.contains(word) { return "`\(word)` is not allowed in a read-only query." }
            if token.kind == .keyword, word == "INTO" { return "SELECT … INTO creates a table; it is not allowed in read-only mode." }
            if token.kind == .keyword, word == "FOR", depth == 0,
               analysis.isWord(index + 1, "UPDATE") || analysis.isWord(index + 1, "SHARE") || analysis.isWord(index + 1, "NO")
                || analysis.isWord(index + 1, "KEY") {
                return "Row-locking clauses (FOR UPDATE / FOR SHARE) are not allowed in read-only mode."
            }
            // Function calls: name ( … ), also schema-qualified.
            if analysis.isPunctuation(index + 1, "(") {
                let name = analysis.lexer.identifierValue(of: token)
                if forbiddenFunctions.contains(name) {
                    return "`\(name)()` has side effects outside the query and is not allowed in read-only mode."
                }
            }
        }
        return nil
    }

    private static func rejection(_ keyword: String) -> String {
        "Only read-only statements (SELECT, WITH … SELECT, VALUES, TABLE, SHOW, EXPLAIN) are allowed; `\(keyword)` statements need a connection with read-write AI access."
    }
}
