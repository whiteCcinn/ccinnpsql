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
        // Writes a READ ONLY transaction does not stop (index pages, catalog and OID counters, statistics flushes), and
        // session state that outlives the transaction. An integration test requires every VOLATILE core function to be
        // forbidden or on its curated list of harmless ones.
        "gin_clean_pending_list", "pg_nextoid", "pg_stop_making_pinned_objects", "pg_extension_config_dump",
        "pg_stat_force_next_flush", "setseed", "loread",
        // Extensions that write past READ ONLY: pg_surgery, pg_visibility.
        "heap_force_kill", "heap_force_freeze", "pg_truncate_visibility_map",
        // Extensions that run SQL given as text: pgTAP (its test functions and internal runners), hypopg. Other extensions
        // may ship more; only the role check and the server's privileges bound those.
        "lives_ok", "throws_ok", "throws_like", "throws_ilike", "throws_matching", "throws_imatching", "results_eq", "results_ne",
        "set_eq", "set_ne", "set_has", "set_hasnt", "bag_eq", "bag_ne", "bag_has", "bag_hasnt", "is_empty", "isnt_empty", "row_eq",
        "performs_ok", "performs_within", "runtests", "do_tap", "_runner", "_temptable", "_docomp", "_relcomp", "hypopg_create_index",
        // pgsql-http: requests to any URL from the server.
        "http", "http_get", "http_post", "http_put", "http_patch", "http_delete", "http_head", "http_request", "http_set_curlopt",
        "http_reset_curlopt", "http_list_curlopt",
    ]

    /// Name prefixes of function families that write, signal, touch server files, execute SQL elsewhere, or read a relation
    /// or run SQL chosen at run time (`table_to_xml(c.oid::regclass …)` with the name built from strings: no name blocklist
    /// sees which relation that is). An integration test enumerates core functions of that kind on each tested version.
    static let forbiddenPrefixes = [
        "table_to_xml", "schema_to_xml", "database_to_xml", "query_to_xml", "cursor_to_xml", "pg_clear_", "pg_restore_",
        "pg_replication_origin_", "pg_stat_reset", "pg_create_", "pg_drop_", "pg_file_", "pg_ls_", "pg_read_", "lo_", "dblink",
        "pg_logical_", "pg_wal_replay_", "pg_xlog_replay_", "pg_advisory_", "pg_try_advisory_", "pg_backup_", "pg_switch_",
        "brin_", "binary_upgrade_", "pg_log_", "pg_rotate_logfile",
        // Extensions that run SQL text in other sessions or on other nodes, or take SQL text as input.
        "pg_background_", "run_command_on_", "pgr_",
    ]

    /// Extension schemas whose functions run SQL given as text or act outside the transaction (orafce: `dbms_sql`,
    /// `dbms_pipe`, `dbms_alert`, `utl_file`; pg_net: `net`, HTTP requests from the server); any name qualified with one is
    /// refused, and so is a session whose search path includes one (the role check).
    static let forbiddenSchemas: Set<String> = ["dbms_sql", "dbms_pipe", "dbms_alert", "utl_file", "net"]

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

    /// The readings a statement must pass: the editor's (keywords under any case mapping, a word after a number is its own
    /// token) and each server version's. Where they differ (`1_0e'…'` holds an E'…' string to one and trailing junk and a
    /// '…' string to another), the statement is allowed only if every reading allows it.
    static let readings: [SQLLexer.Syntax] = [.editor] + SQLLexer.Syntax.servers

    /// Exactly one statement with no `;` anywhere outside strings and comments: the only text read-only access sends over
    /// the simple query protocol (which runs every statement of a message).
    public static func isSingleStatement(_ sql: String) -> Bool {
        let tokens = SQLLexer(sql).tokens().filter { $0.kind != .comment }
        let lexer = SQLLexer(sql)
        return !tokens.isEmpty && !tokens.contains { $0.kind == .punctuation && lexer.units[$0.range].elementsEqual([0x3B]) }
    }

    /// What a secret source shows, which decides the refusal's advice.
    enum SecretKind: Sendable {
        /// Other sessions' SQL text: the redacted tools show it.
        case sessionSQL
        /// Credentials, connection strings, server files.
        case credentials
        /// Role, database, server or extension settings, which can hold secrets (`ALTER ROLE app SET myapp.api_key = '…'`).
        case settings
        /// Role catalogs whose every row includes the role's settings (`rolconfig`, `useconfig`), so `SELECT *` or a
        /// whole-row reference shows them.
        case roleSettings
    }

    /// Views, tables, functions and columns that show other sessions' SQL text, connection strings, credentials or settings
    /// that can hold secrets: only the redacted tools (get_activity, get_top_statements, get_replication) read the first.
    /// Security-critical: an integration test enumerates every pg_catalog view, table and function with a `query`,
    /// `conninfo`, `password`, `options`, `config` or `setting` result column on each tested version and requires it here,
    /// in the forbidden functions, or on its list of proven-harmless ones, so a new version's additions fail the test
    /// instead of leaking. (`pg_read_file`, `pg_read_binary_file`, `pg_ls_*`, `pg_stat_file`, `dblink*`, `lo_*` are
    /// forbidden functions; `secretPrefixes` covers families such as every `pg_stat_statements*` name.)
    static let secretSources: [String: SecretKind] = [
        // Other sessions' SQL text.
        "pg_stat_activity": .sessionSQL, "pg_stat_get_activity": .sessionSQL, "pg_stat_get_backend_activity": .sessionSQL,
        // pgsentinel's session history.
        "pg_active_session_history": .sessionSQL,
        // Credentials, connection strings, server files.
        "pg_authid": .credentials, "pg_shadow": .credentials, "pg_user_mappings": .credentials, "pg_user_mapping": .credentials,
        "pg_subscription": .credentials, "pg_stat_wal_receiver": .credentials, "pg_stat_get_wal_receiver": .credentials,
        "pg_stat_replication": .credentials, "pg_foreign_server": .credentials, "pg_foreign_data_wrapper": .credentials,
        "pg_foreign_table": .credentials, "pg_largeobject": .credentials, "pg_hba_file_rules": .credentials,
        "pg_ident_file_mappings": .credentials, "pg_current_logfile": .credentials,
        // Settings: server files, role and database settings (also as columns, whatever relation shows them), all settings.
        "pg_file_settings": .settings, "pg_show_all_file_settings": .settings, "pg_db_role_setting": .settings, "setconfig": .settings,
        "rolconfig": .settings, "useconfig": .settings, "pg_settings": .settings, "pg_show_all_settings": .settings,
        "pg_roles": .roleSettings, "pg_user": .roleSettings,
    ]

    /// Name families of `secretSources`: pg_stat_statements and the extensions that keep other sessions' SQL (pg_stat_monitor,
    /// pg_store_plans, pg_qualstats, pg_stat_kcache, pg_show_plans, PoWA) or settings history (pg_track_settings). Other
    /// extensions may add more.
    static let secretPrefixes: [(prefix: String, kind: SecretKind)] = [
        ("pg_stat_statements", .sessionSQL), ("pg_stat_monitor", .sessionSQL), ("pg_store_plans", .sessionSQL),
        ("pg_qualstats", .sessionSQL), ("pg_stat_kcache", .sessionSQL), ("pg_show_plans", .sessionSQL), ("powa_", .sessionSQL),
        ("pg_track_settings", .settings),
    ]

    /// What `name` shows when it is one of `secretSources` (as a relation, a function or a column), else `nil`.
    static func secretKind(of name: String) -> SecretKind? {
        secretSources[name] ?? secretPrefixes.first { name.hasPrefix($0.prefix) }?.kind
    }

    static func isSecretSource(_ name: String) -> Bool {
        secretKind(of: name) != nil
    }

    private static func secretRefusal(_ name: String, _ kind: SecretKind) -> String {
        switch kind {
        case .sessionSQL:
            "`\(name)` shows other sessions' SQL text; use get_activity or get_top_statements, which redact it."
        case .credentials:
            "`\(name)` can show credentials, connection strings or server files; it is not readable in read-only AI mode "
                + "(get_replication shows replication status without them)."
        case .settings:
            "`\(name)` shows role, database or server settings, which can hold secrets; \(settingsAdvice)"
        case .roleSettings:
            "`\(name)` includes each role's settings (rolconfig), which can hold secrets; use list_roles for roles, their "
                + "attributes and memberships."
        }
    }

    private static let settingsAdvice = "use get_settings, or read a built-in parameter with SHOW name or current_setting('name')."

    /// SHOW names exactly one built-in parameter: one plain, unquoted ASCII word other than ALL, and nothing after it. Every
    /// built-in name is such a word. Custom parameters have a dot and can hold secrets set with `ALTER ROLE / DATABASE … SET`;
    /// a quoted or escaped name can spell a dot or ALL (`SHOW "all"`); `SHOW ALL` lists the custom parameters extensions
    /// define. The multi-word forms have one-word names (`timezone`, `transaction_isolation`, `session_authorization`).
    private static func checkShow(_ analysis: StatementWords, from first: Int) -> String? {
        let name = first + 1
        if name + 1 == analysis.tokens.count, analysis.tokens[name].kind == .keyword || analysis.tokens[name].kind == .identifier,
           isPlainName(analysis.lexer.text(of: analysis.tokens[name])), analysis.words[name] != "ALL" {
            return nil
        }
        return "In read-only mode SHOW takes one built-in parameter name, unquoted (SHOW work_mem; SHOW timezone for SHOW TIME ZONE): "
            + "quoted, escaped or dotted names and SHOW ALL can show settings that hold secrets. Use get_settings to list built-in parameters."
    }

    /// `text` with ASCII letters lower-cased and every other character kept: how PostgreSQL folds an unquoted name in a
    /// multi-byte database.
    static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (0x41...0x5A).contains($0.value) ? Unicode.Scalar($0.value + 0x20) ?? $0 : $0 }))
    }

    /// `[A-Za-z_][A-Za-z0-9_]*`: how every built-in parameter is spelled.
    private static func isPlainName(_ text: String) -> Bool {
        func isLetter(_ unit: UInt8) -> Bool { unit == 0x5F || (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
        guard let head = text.utf8.first, isLetter(head) else { return false }
        return text.utf8.allSatisfy { isLetter($0) || (0x30...0x39).contains($0) }
    }

    /// `current_setting(…)` whose `(` is at `open`: allowed with one literal, built-in parameter name (no dot), so neither a
    /// custom parameter nor a name built at run time is read.
    private static func checkSettingLookup(_ analysis: StatementWords, open: Int) -> String? {
        let argument = open + 1
        if analysis.tokens.indices.contains(argument), analysis.tokens[argument].kind == .string,
           let name = literalContent(analysis.lexer.text(of: analysis.tokens[argument])), !name.contains("."),
           analysis.isPunctuation(argument + 1, ")") || analysis.isPunctuation(argument + 1, ",") {
            return nil
        }
        return "current_setting() takes one literal, built-in parameter name in read-only mode: custom parameters (names with a "
            + "dot) can hold secrets, and a name built at run time could be one."
    }

    /// `nil` when allowed; otherwise the reason it is rejected. Before the database is known.
    public static func check(_ sql: String) -> String? {
        check(sql, singleByteEncoding: nil)
    }

    /// `nil` when allowed; otherwise the reason it is rejected. `singleByteEncoding` names the database's encoding when it is
    /// single-byte (read by the role check), where unquoted names must be ASCII; `untrustedFunctions` are the names of the
    /// session's callable functions in untrusted languages (read by the role check), refused when called by name.
    public static func check(_ sql: String, singleByteEncoding: String?, untrustedFunctions: Set<String> = []) -> String? {
        // The guard checks exactly what is sent, and a NUL cannot be (the transport refuses it): one anywhere, literals
        // included, is refused rather than read as a separator (`pg_read\0_file`, `IN\0TO`).
        guard !sql.utf16.contains(0) else { return "The SQL contains a NUL character; it is not allowed in read-only mode." }
        for syntax in readings {
            let reading = Reading(syntax: syntax, singleByteEncoding: singleByteEncoding, untrustedFunctions: untrustedFunctions)
            if let reason = check(sql, depth: 0, reading: reading) { return reason }
        }
        return nil
    }

    /// One pass over the text: how it is tokenized, the database's encoding when it is single-byte, and the session's
    /// callable functions in untrusted languages.
    private struct Reading {
        let syntax: SQLLexer.Syntax
        let singleByteEncoding: String?
        let untrustedFunctions: Set<String>
    }

    /// Letters whose upper, lower or title case holds an ASCII letter (`İ` lower-cases to `i̇`, `ſ` upper-cases to `S`, `K`
    /// is the Kelvin sign, `ﬁ` upper-cases to `FI`): a server that folds names by locale or by full case mapping can turn a
    /// name holding one into another name (`PG_SETTİNGS` is `pg_settings` in a Turkish LATIN5 database). Exactly the 19 that
    /// Unicode has; a unit test derives the set from Unicode's case mappings. Every ccinn app refuses them in names.
    static let caseUnsafeLetters: Set<Unicode.Scalar> = [
        "\u{00DF}", "\u{0130}", "\u{0131}", "\u{0149}", "\u{017F}", "\u{01F0}", "\u{1E96}", "\u{1E97}", "\u{1E98}", "\u{1E99}", "\u{1E9A}",
        "\u{212A}", "\u{FB00}", "\u{FB01}", "\u{FB02}", "\u{FB03}", "\u{FB04}", "\u{FB05}", "\u{FB06}",
    ]

    /// A name a server could fold into a different one: in every encoding, a name, keyword or quoted name holding one of
    /// `caseUnsafeLetters`; in a single-byte database, an unquoted name or keyword with any non-ASCII letter (PostgreSQL
    /// lower-cases high-bit bytes there with the locale's tolower(), which the client cannot model). Quoted names are
    /// otherwise exact, and string literals are data.
    private static func nameRefusal(_ analysis: StatementWords, at index: Int, singleByteEncoding: String?) -> String? {
        let token = analysis.tokens[index]
        guard token.kind == .keyword || token.kind == .identifier || token.kind == .quotedIdentifier else { return nil }
        let raw = analysis.lexer.text(of: token)
        if raw.unicodeScalars.contains(where: caseUnsafeLetters.contains) {
            return "`\(raw)` contains a letter whose upper or lower case is an ASCII letter (such as İ, ı, ſ, ß, K or ﬁ), which a server "
                + "can fold into a different name; spell the name in ASCII."
        }
        if let singleByteEncoding, token.kind != .quotedIdentifier, !raw.unicodeScalars.allSatisfy(\.isASCII) {
            return "`\(raw)` is not allowed: this database uses a single-byte encoding (\(singleByteEncoding)), where the server folds "
                + "non-ASCII letters in names by locale; quote the name or use ASCII."
        }
        return nil
    }

    /// `depth`: how many string literals deep `sql` was found (0 for the statement itself).
    private static func check(_ sql: String, depth: Int, reading: Reading) -> String? {
        let syntax = reading.syntax
        let statements = SQLStatementSplitter.split(sql, syntax: syntax)
        guard let statement = statements.first else { return "The statement is empty." }
        guard statements.count == 1 else { return "Only one statement can be run at a time; send statements separately." }
        if let reason = ambiguity(in: statement.text, syntax: syntax) { return reason }
        let analysis = StatementWords(statement.text, syntax: syntax)
        if let reason = lexicalRefusal(in: analysis) { return reason }
        for index in analysis.tokens.indices {
            if let reason = nameRefusal(analysis, at: index, singleByteEncoding: reading.singleByteEncoding) { return reason }
        }
        let first = analysis.firstWordIndex()
        guard first < analysis.words.count else { return "The statement is empty." }
        switch analysis.words[first] {
        case "SELECT", "WITH", "VALUES", "TABLE":
            return checkQuery(analysis, from: first, depth: depth, reading: reading)
        case "SHOW":
            return checkShow(analysis, from: first)
        case "EXPLAIN":
            let (_, body) = SQLStatementKind.explainTarget(analysis, at: first)
            let bodyFirst = analysis.firstWordIndex(from: body)
            guard bodyFirst < analysis.words.count, ["SELECT", "WITH", "VALUES", "TABLE"].contains(analysis.words[bodyFirst]) else {
                return "Only EXPLAIN of a SELECT query is allowed in read-only mode."
            }
            return checkQuery(analysis, from: bodyFirst, depth: depth, reading: reading)
        default:
            return rejection(analysis.words[first])
        }
    }

    /// Text that another reading could split into more statements than the lexer sees: where PostgreSQL versions, settings
    /// or other tools may read it differently, the guard refuses rather than pick one reading.
    /// - a `;` inside the statement (the splitter keeps those of `BEGIN ATOMIC` bodies and parentheses together);
    /// - a nested block comment (one comment to PostgreSQL, code after the first `*/` to a reader that does not nest);
    /// - a backslash before a quote in a standard string (`'a\''` ends early while standard_conforming_strings is off).
    static func ambiguity(in statement: String, syntax: SQLLexer.Syntax) -> String? {
        let lexer = SQLLexer(statement, syntax: syntax)
        for token in lexer.tokens() {
            let units = lexer.units[token.range]
            switch token.kind {
            case .punctuation where units.elementsEqual([0x3B]):
                return "Only one statement can be run at a time; send statements separately."
            case .comment where units.starts(with: [0x2F, 0x2A]) && units.dropFirst(2).indices.contains(where: { index in
                index + 1 < token.range.upperBound && lexer.units[index] == 0x2F && lexer.units[index + 1] == 0x2A
            }):
                return "Nested block comments are not allowed in read-only mode."
            case .string where isStandardString(units) && units.indices.dropFirst().contains(where: { index in
                lexer.units[index] == 0x27 && lexer.units[index - 1] == 0x5C
            }):
                return "A backslash before a quote in a '…' string reads differently when standard_conforming_strings is off; "
                    + "use E'…' or a doubled quote."
            default:
                break
            }
        }
        return nil
    }

    /// The single lexical checkpoint, run on every statement before it is classified (whatever its verb) and on the content
    /// of every string literal: U&-escaped identifiers and `UESCAPE`, which can spell any name or keyword
    /// (`SHOW U&"app\002ejwt_secret"` is `SHOW app.jwt_secret`), then `programOrAtomicBody`.
    static func lexicalRefusal(in analysis: StatementWords) -> String? {
        for (index, token) in analysis.tokens.enumerated() {
            if token.kind == .quotedIdentifier {
                let raw = analysis.lexer.text(of: token)
                if raw.hasPrefix("U&") || raw.hasPrefix("u&") {
                    return "Unicode-escaped identifiers (U&\"…\") are not allowed in read-only mode."
                }
            } else if token.kind == .keyword || token.kind == .identifier, analysis.words[index] == "UESCAPE" {
                return "UESCAPE is not allowed in read-only mode."
            }
        }
        return programOrAtomicBody(in: analysis)
    }

    /// `TO PROGRAM` / `FROM PROGRAM` (COPY running a shell command, which a READ ONLY transaction does not stop), in any
    /// case, anywhere (string literals read as SQL included); and `BEGIN ATOMIC`, which is never part of a read.
    static func programOrAtomicBody(in analysis: StatementWords) -> String? {
        for index in analysis.tokens.indices where analysis.isWord(index, "PROGRAM") || analysis.isWord(index, "ATOMIC") {
            let previous = index - 1
            if analysis.words[index] == "PROGRAM", analysis.isWord(previous, "TO") || analysis.isWord(previous, "FROM") || analysis.isWord(previous, "COPY") {
                return "COPY … TO / FROM PROGRAM runs a server-side command; it is not allowed in read-only mode."
            }
            if analysis.words[index] == "ATOMIC", analysis.isWord(previous, "BEGIN") {
                return "BEGIN ATOMIC is not allowed in read-only mode."
            }
        }
        return nil
    }

    /// `'…'` or `N'…'`: the strings whose backslashes depend on standard_conforming_strings.
    private static func isStandardString(_ units: ArraySlice<UInt16>) -> Bool {
        guard let first = units.first else { return false }
        if first == 0x27 { return true }
        return (first == 0x4E || first == 0x6E) && units.dropFirst().first == 0x27
    }

    private static func checkQuery(_ analysis: StatementWords, from start: Int, depth: Int, reading: Reading) -> String? {
        guard SQLStatementKind.classify(analysis, from: start) == .query else {
            return "The statement writes data (a data-modifying WITH or SELECT … INTO); it is not allowed in read-only mode."
        }
        if let reason = forbiddenCall(in: analysis, reading: reading) { return reason }
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
        return checkLiterals(in: analysis, depth: depth + 1, reading: reading)
    }

    /// Secret sources, names in forbidden schemas, and calls to forbidden functions (also schema-qualified or quoted). Runs
    /// after `lexicalRefusal`, so no name here is U&-escaped.
    private static func forbiddenCall(in analysis: StatementWords, reading: Reading) -> String? {
        for (index, token) in analysis.tokens.enumerated() {
            guard token.kind == .keyword || token.kind == .identifier || token.kind == .quotedIdentifier else { continue }
            let name = analysis.lexer.identifierValue(of: token)
            if let kind = secretKind(of: name) { return secretRefusal(name, kind) }
            if forbiddenSchemas.contains(name), analysis.isPunctuation(index + 1, ".") {
                return "Functions in `\(name)` run SQL given as text or act outside the transaction; they are not allowed in read-only mode."
            }
            if analysis.isPunctuation(index + 1, "(") {
                // A call in literal content that is not a statement is checked here (data is not a name).
                if let reason = nameRefusal(analysis, at: index, singleByteEncoding: reading.singleByteEncoding) { return reason }
                if isForbiddenFunction(name) {
                    return "`\(name)()` has side effects outside the query and is not allowed in read-only mode."
                }
                // As the server resolves it: an unquoted name folds ASCII letters only (multi-byte encodings), a quoted one is exact.
                let serverName = token.kind == .quotedIdentifier ? name : asciiLowercased(analysis.lexer.text(of: token))
                if reading.untrustedFunctions.contains(name) || reading.untrustedFunctions.contains(serverName) {
                    return "`\(serverName)()` is a function in an untrusted language that this role can execute; it runs with the server's "
                        + "access, so read-only AI access refuses calls to it."
                }
                if name == "current_setting", let reason = checkSettingLookup(analysis, open: index + 1) { return reason }
            }
        }
        return nil
    }

    /// Many functions run SQL given as text (`ts_stat`, `query_to_xml`, `crosstab`, `pgr_*`, `dblink`, any function that
    /// does `EXECUTE`); a denylist always misses one. So the content of every string literal (adjacent literals joined,
    /// escapes decoded) is read as SQL again: content that starts with a statement verb must pass the whole guard, and
    /// no content may call a forbidden function. Conservative by design: text that merely looks like a write is refused.
    private static func checkLiterals(in analysis: StatementWords, depth: Int, reading: Reading) -> String? {
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
            if isText, let reason = checkEmbedded(content, depth: depth, reading: reading) { return reason }
        }
        return nil
    }

    private static func checkEmbedded(_ text: String, depth: Int, reading: Reading) -> String? {
        let syntax = reading.syntax
        let inner = StatementWords(text, syntax: syntax)
        guard !inner.tokens.isEmpty else { return nil }
        if let reason = lexicalRefusal(in: inner) { return "A string literal contains SQL that is not allowed in read-only mode: \(reason)" }
        guard depth <= maxLiteralDepth else { return "SQL is nested too deeply in string literals for a read-only query." }
        // Content of which any statement starts with a verb (after any `(`, and whatever precedes it: `;COPY …`) is SQL
        // (`$$x; DROP TABLE t$$` holds a second statement): it must pass the whole guard, which takes one statement only.
        let startsWithVerb = { (statement: SQLStatement) -> Bool in
            let words = StatementWords(statement.text, syntax: syntax)
            let first = words.firstWordIndex()
            return first < words.tokens.count && (words.tokens[first].kind == .keyword || words.tokens[first].kind == .identifier)
                && statementVerbs.contains(words.words[first])
        }
        if SQLStatementSplitter.split(text, syntax: syntax).contains(where: startsWithVerb) {
            guard let reason = check(text, depth: depth, reading: reading) else { return nil }
            return "A string literal contains SQL that is not allowed in read-only mode: \(reason)"
        }
        if let reason = forbiddenCall(in: inner, reading: reading) { return "A string literal contains SQL that is not allowed in read-only mode: \(reason)" }
        return checkLiterals(in: inner, depth: depth + 1, reading: reading)
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
