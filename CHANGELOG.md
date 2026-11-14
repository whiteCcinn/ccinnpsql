# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
- MCP server (`CcinnPsql mcp`) so AI clients such as Claude Code, Codex and Claude Desktop can list connections, inspect servers, schemas, tables, statistics, activity, replication and top statements, and run read-only queries (checked by the app and executed in a READ ONLY transaction) on connections the user opted in; read & write access is opt-in per connection, and every call is audited with secrets redacted.

[Unreleased]: https://github.com/whiteCcinn/ccinnpsql/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/whiteCcinn/ccinnpsql/releases/tag/v1.0.0
