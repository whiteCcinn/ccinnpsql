# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.3.1] - 2026-11-18

### Fixed

- The release build failed for 1.3.0: the compiler the release workflow uses (Swift 6.2) gave up type-checking two expressions in the `get_settings` and `list_roles` tools. 1.3.0 was tagged but never published. 1.3.1 contains everything listed under 1.3.0, with those two expressions rewritten; nothing else changed.

## [1.3.0] - 2026-11-18

### Added

- **Precise, live error markers.** When a statement fails, the editor underlines exactly the text the error is about. The marker:
  - comes from the server's position (counted in code points, so emoji and CJK before the error do not shift it);
  - widens to the qualified name the error names (`shop.nosuch_table`, `t.nme`) or to the whole call of an unknown function (`abs(1,2,3)`);
  - marks the opener of an unterminated string, dollar quote or comment;
  - points into the body of a `CREATE FUNCTION` that failed.

  Without a position:
  - errors raised inside `DO` blocks are located from the internal query, the named object or the `CONTEXT` line;
  - errors such as `table "x" does not exist` (DROP) and constraint violations mark the object they name, matched with PostgreSQL's case folding.
- The message and PostgreSQL's **HINT** (e.g. `Perhaps you meant to reference the column "t.name".`) are shown next to the line. A status bar under the editor shows the problem at the cursor with its line and column, previous / next, and the cursor position.
- The result shows the error kind with its editor position, the SQLSTATE with its condition name (`42703 · undefined_column`), the hint and **Show in Editor**.
- **Checks while typing**: unterminated strings, quoted identifiers, dollar quotes and (nested) block comments, unclosed or unmatched parentheses and brackets. They run locally, without contacting the server, and never flag `CREATE RULE … DO (a; b)` or `BEGIN ATOMIC` bodies.
- **Format SQL** (⌥⌘L, the toolbar's **Format** button, or Edit ▸ Format SQL) formats the selection, or the whole script, as one undoable edit:
  - main clauses on their own lines, including `RETURNING`, `ON CONFLICT`, `FETCH FIRST` and `FOR UPDATE`;
  - one item per line in multi-item lists;
  - `AND`/`OR` conditions broken in WHERE / HAVING / ON;
  - indented subqueries and CTEs, and multi-branch CASE split;
  - `CREATE TABLE` column lists one per line.

  Only whitespace and the case of keywords change: words PostgreSQL reserves, and other keywords only where their position makes them keywords (`ORDER BY`, join operators, window frames, `NULLS FIRST`, locking clauses, triggers, …). Names (also names spelled like keywords, such as a column `rows`, `t.from` or a CTE called `recursive`), functions, type names, strings, dollar-quoted function bodies, quoted identifiers and comments keep their exact text. A word next to `.` is always a name (`t.end`, `end.x`), so is a word with a non-ASCII letter (`ſelect`, `ﬁrst`: PostgreSQL folds only ASCII letters), and `values` or `set` used as a column or alias keeps its text and its line. Text written together stays together (`123abc`, `$1::int`, `date'2024-01-01'`, `U&'…'UESCAPE'…'`), and two string literals keep the line break that makes PostgreSQL join them. Lines end as the input's do (also CRLF). A selection is widened to whole tokens. The result is re-checked token by token, reading numbers the way PostgreSQL 13–14 and 16+ each do (`123abc`, `0x1F`, `1_000`) and strings with `standard_conforming_strings` on and off; if it would differ, nothing changes and the status says why. Text with a vertical tab between tokens (whitespace to PostgreSQL 16+, an error to 13) is not formatted. Formatting runs in the background, stops as soon as you type, and never replaces text while an input method is composing. **Settings → General** has keyword case (UPPER / lower / Unchanged) and indent (2 / 4 spaces).

### Changed

- Error markers follow edits: they move with text typed above them (also while the statement is still running) and disappear as soon as the failing statement is edited or the text is replaced.
- Markers now also work for **Run as Script** (positions are relative to the whole script; an error without a position is searched only in the statement that failed) and for `EXPLAIN` of a statement that already starts with `EXPLAIN`.
- The result's statement-relative "Position" row is replaced by the editor position in the error heading.
- The editor now splits operators as PostgreSQL does (`a=-1` is `=` followed by `-1`) and highlights `CURRENT_CATALOG`, `LOCALTIME`, `LOCALTIMESTAMP`, `GROUPS` and `OTHERS` as keywords.
- Numbers are read as PostgreSQL 16 reads them: `0x1F`, `0o17`, `0b101` and `1_000` are numbers, `0or` is `0 or`, `t.5` is `t` followed by `.5`, and `..` is one token. A word written right after a number is still its own token (`1.5into` is `1.5` and `INTO`, as PostgreSQL 13–14 read it).
- The MCP read-only check takes every reading where readers could disagree: a statement must pass as PostgreSQL 13–14 and 16+ each tokenize it and with keywords matched under any case mapping. It also refuses a nested block comment and a backslash before a quote in a `'…'` string (which ends it early when `standard_conforming_strings` is off); `run_query` already pins that setting on and runs one statement over the extended protocol in a READ ONLY transaction. `SELECT 1.5into t` (which creates a table on PostgreSQL 13) was already refused in 1.2.0.

### Fixed

- Starting a connect in a window (a double-click, a second Connect) cancels one still in flight there, instead of leaving its connection and tunnel open. A cancelled connect's late progress no longer replaces the new connect's status.
- SSH tunnels never use or become a shared `ControlMaster`. With `ControlMaster auto` in `~/.ssh/config`, a tunnel could become the master, so closing its window cut the other windows and the terminal sessions multiplexed over it. It could also join a master you already had: that master then owned the forwarded port, which kept forwarding to the database after the window closed (one more port with every connect), and the profile's SSH credentials were never used. Each tunnel now has its own SSH connection; your own sessions keep their master.

### Security

- **AI read-only mode could run server programs on a privileged role (1.2.0).** In 1.2.0, on a connection whose role was a superuser or could run server programs, AI read-only mode could be made to run server programs through a function that executes dynamic SQL: `COPY … TO PROGRAM` (and `COPY … TO` a file) is not blocked by a READ ONLY transaction, and no text check can see SQL built at run time. One form even passed the check as plain text: a string literal starting with `;` (`SELECT f(';COPY (SELECT 1) TO PROGRAM ''…''')`), which the check did not re-read as SQL. 1.3.0 refuses AI read-only access on such roles unless explicitly allowed per connection: a superuser, or a role that reaches `pg_execute_server_program`, `pg_read_server_files` or `pg_write_server_files` through any chain of memberships (also `pg_read_all_stats`, `pg_read_all_settings` and `pg_monitor`, which read every session's SQL and every setting), checked in the call's own transaction before every call, failing closed. Settings → MCP has **Allow AI read-only access on a privileged role** (off by default) and **Check Role**; callable `SECURITY DEFINER` functions owned by privileged roles are reported, not refused. Every statement inside a literal is now checked too, and `TO PROGRAM` / `FROM PROGRAM` is refused anywhere.
- **A NUL character could split names and keywords past the read-only check (1.2.0).** The client removed NUL characters just before sending, while the check read them as separators, so `pg_read\0_file(…)` or `IN\0TO` passed and the server ran what the check refuses: reading server files with `pg_read_file` (role permitting), listing directories, or cancelling other sessions. The client now refuses to send any text with a NUL (the workbench reports it instead of running different SQL), and the read-only check refuses a NUL anywhere.
- **`BEGIN ATOMIC` hid statements from the read-only check (1.2.0).** It was recognised anywhere, so `SELECT … begin atomic; COMMIT; SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE; END` counted as one statement and passed. `run_query` sends one statement over the extended protocol, which refuses such text, but on a **PgBouncer admin console** connection it sends `SHOW` text over the simple query protocol, which runs every statement of a message (PgBouncer 1.24 itself rejects such a message as an invalid command; other versions were not checked). `BEGIN ATOMIC` now opens a body only in `CREATE [OR REPLACE] FUNCTION / PROCEDURE`, read-only access refuses it and any `;` inside a statement (`SHOW` included), and the console path never sends more than one statement.
- **Other sessions' SQL reached the AI with its literals (1.2.0).** `get_activity` and `get_top_statements` returned other sessions' statements as written, so a password in `ALTER ROLE … PASSWORD '…'`, a token in a string or any other literal reached the AI. They now replace every string and numeric literal with `?` and drop comments. Read-only `run_query` refuses the raw sources: `pg_stat_activity`, every `pg_stat_statements*`, `pg_authid`, `pg_shadow`, user mappings, subscriptions, WAL receiver and replication views, foreign server / wrapper / table options, `pg_largeobject`, `pg_file_settings`, `pg_hba_file_rules`, `pg_ident_file_mappings`, `pg_current_logfile()`, and the views of other sessions' SQL from pg_stat_monitor, pg_store_plans, pg_qualstats, pg_stat_kcache, pg_show_plans, pgsentinel and PoWA. Built-ins that read a relation or run SQL chosen at run time (`table_to_xml`, `schema_to_xml`, `database_to_xml` and their siblings, besides the already forbidden `query_to_xml`, `cursor_to_xml`, `ts_stat`, `ts_rewrite`) are forbidden, since a name list cannot see them. Integration tests keep both lists complete on every tested version.
- **Role and database settings reached the AI (1.2.0).** Settings made with `ALTER ROLE … SET` or `ALTER DATABASE … SET` can hold secrets (`myapp.api_key`), and AI read-only mode could read them from `pg_roles.rolconfig`, `pg_user.useconfig`, `pg_db_role_setting` or `current_setting('myapp.api_key')`. Read-only `run_query` now refuses those catalogs (`pg_roles` and `pg_user` as a whole, since `SELECT *` includes the settings), `pg_settings`, `SHOW ALL`, and custom parameters (names with a dot): `SHOW` takes one plain, unquoted parameter name (never quoted, Unicode-escaped or dotted, never `ALL`), and `current_setting()` one literal, built-in parameter name. Unicode-escaped names (`U&"…"`, `UESCAPE`) are refused in every statement, not only in queries. Two new MCP tools take their place: `get_settings` lists built-in parameters (never custom ones), and `list_roles` lists roles with their attributes and memberships (never role settings, passwords or password expiry). A function already in the database that reads a setting by a name built at run time can still read it.
- **AI read-only mode could change indexes (1.2.0).** A READ ONLY transaction does not stop `brin_summarize_new_values`, `brin_summarize_range`, `brin_desummarize_range` or `gin_clean_pending_list`, which change index pages, and 1.2.0 allowed them. They are now refused, with other functions whose effects outlive the transaction (`setseed`, `pg_log_standby_snapshot`, `pg_nextoid`, …) and extension functions that write past it (pg_surgery's `heap_force_kill` / `heap_force_freeze`, pg_visibility's `pg_truncate_visibility_map`). An integration test requires every VOLATILE core function to be refused or on a reviewed list of harmless ones, on every tested version.
- **Turkish letters folded names past the read-only check (1.2.0).** In a LATIN5 or WIN1254 database with a Turkish locale, the server lower-cases `İ` to `i`, so `PG_SETTİNGS`, `current_settİng('app.jwt_secret')`, `SET_CONFİG` or `pg_termİnate_backend` reached the real objects while the check saw different names, and a plain role read the database and role secrets. Names holding one of the 19 letters whose case maps to ASCII (`İ ı ſ ß K ﬁ …`) are now refused in every database, and in a single-byte database (LATIN*, WIN125*, SQL_ASCII, …), whose encoding every call now reads, an unquoted name must be ASCII.
- Extension functions known to run SQL given as text are refused by name: pgTAP (`lives_ok`, `throws_ok`, `results_eq`, `set_eq`, `bag_eq`, `is_empty`, `row_eq`, `performs_ok`, `runtests`, …), orafce's `dbms_sql.*` (with `dbms_pipe`, `dbms_alert` and `utl_file`) and `hypopg_create_index`. A connection whose search path includes one of orafce's schemas is refused, since an unqualified call would reach them. Other extensions may ship more; only the role check and the server's privileges bound those.
- **Functions in untrusted languages read server files as any role (1.2.0).** A superuser's `CREATE FUNCTION … LANGUAGE internal AS 'pg_read_file_all'` (or a C, plpython3u or plperlu function) is executable by PUBLIC by default, and AI read-only mode could call it as a plain role. Such functions the role can execute, outside `pg_catalog` and a short list of reviewed extensions, are now listed with every response and refused when called by name. Views, operators, casts, defaults and row security can still call them; the real control is a role without EXECUTE on them. pg_net (`net.*`) and pgsql-http (`http_get`, …) are refused too.
- Readable foreign tables whose options run a server program or read a server file (file_fdw `program` / `filename`) are reported like `SECURITY DEFINER` helpers, in `security_notices` and **Check Role**. Error responses now carry `security_notices` too.
- Every read-only call also checks that the session's `client_encoding` is UTF8, and the check runs on the exact text sent after the automatic LIMIT or the EXPLAIN prefix. MCP tool arguments other than the SQL (connection, database, schema, table, filters) are refused when they hold a control character, and identifier and literal quoting no longer drops a NUL (the statement is refused instead of naming a different object).

## [1.2.0] - 2026-11-17

### Added

- **Multiple windows made easy.** File ▸ **New Window with This Connection** (⇧⌘N) and the toolbar's **New Window** button open the current connection in another window, with the password already in use, so unsaved connections and passwords not in the Keychain work too. Saved connections have **Open in New Window**. Every window keeps its own connection; closing one disconnects only that window. A window that macOS restores after a relaunch shows the connection screen and never connects by itself.

## [1.1.0] - 2026-11-16

### Added

- **Check for Updates…** in the app menu. When a newer release exists, CcinnPsql shows its version and release notes. **Download & Open** downloads the disk image, verifies its size and SHA-256 against the release's `SHA256SUMS.txt`, saves it to Downloads without overwriting anything, and opens it. **Release Page**, **Skip This Version** and **Later** are also available.
- A quiet automatic check at most once a day (retried after an hour when offline), on by default, switchable in **Settings → General → Updates**.
- Project links: the Help menu now has **CcinnPsql on GitHub**, **Release Notes** and **Report an Issue…**; the About window shows the GitHub link; Settings → General shows the version and project links.

### Fixed

- **Stop** pressed while the SQL editor is still connecting, or the instant a statement starts, is no longer ignored: a statement that has not reached the server is not sent, and one that has is cancelled.

## [1.0.0] - 2026-11-15

First public release.

### Added

- Pure-Swift PostgreSQL protocol v3 client: startup, TLS after SSLRequest on the same socket and PostgreSQL 17 direct TLS (`sslmode` disable / prefer / require / verify-ca / verify-full, custom CA file), SCRAM-SHA-256 with server-signature verification, MD5, trust and opt-in clear-text passwords, simple and extended query protocol, multiple result sets, notices, LISTEN/NOTIFY, COPY TO STDOUT, binary decoding that matches PostgreSQL's text output, and race-free CancelRequest cancellation. Tested against PostgreSQL 9.6 and 10–18.
- PgBouncer and Pgpool-II awareness: transaction pooling is detected (or set per connection) and session features degrade with an explanation; the PgBouncer admin console works for `SHOW` reports; Pgpool operations are routed to the primary.
- Connection manager with favourites, recents, colour tags, TLS state, connection testing, SSH tunnels and Keychain-backed secrets.
- Browser for databases and schemas: tables (partitions nested under partitioned tables, inheritance children under their parent), views, materialized views, foreign tables, sequences, functions, procedures, aggregates, types and extensions; TimescaleDB hypertable and Citus placement markers.
- Table insights: columns, constraints, indexes with scans, unused flags and bloat estimates, triggers, partitions, heap/TOAST/index sizes, tuple and vacuum statistics, transaction-ID age, table bloat estimate, reconstructed DDL, grants and a data preview; sequence headroom, function definitions, enum/composite/domain details, PostGIS columns, hypertable facts; materialized-view refresh (also CONCURRENTLY).
- Operations: overview, activity with wait events and a blocking tree, cancel/terminate guarded by the node the session was observed on, locks, replication and slots with lag, `pg_stat_progress_*`, top statements from pg_stat_statements, maintenance candidates and unused indexes, settings and roles.
- SQL workbench: PostgreSQL highlighting, context-aware completion, run current / selection / all / as script, automatic LIMIT, exact error underline with SQLSTATE, detail and hint, notices, transaction state, cancellation, history, CSV/TSV/JSON/Markdown/INSERT export and COPY export, charts, visual EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON), and a LISTEN/NOTIFY panel.
- MCP server (`CcinnPsql mcp`) so AI clients such as Claude Code, Codex and Claude Desktop can list connections, inspect servers, schemas, tables, statistics, activity, replication and top statements, and run read-only queries (checked by the app, including SQL inside string literals, executed in a READ ONLY transaction, with the session reset after every call) on connections the user opted in; read & write access is opt-in per connection, and every call is audited with secrets redacted.

[Unreleased]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/whiteCcinn/ccinnpsql/releases/tag/v1.0.0
