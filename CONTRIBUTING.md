# Contributing to CcinnPsql

Thanks for taking the time to contribute! This document explains how to set up a development environment and what we expect from changes.

## Development setup

- macOS 14 or later, Xcode 16 or later (Swift 6).
- Docker, if you want to run the integration tests against real PostgreSQL servers.

```bash
git clone https://github.com/whiteCcinn/ccinnpsql.git
cd ccinnpsql
swift build
swift test --skip IntegrationTests
scripts/build-app.sh --open
```

### Integration tests

```bash
scripts/pg-up.sh 9.6 13 17 18                               # TLS, auth matrix, pg_stat_statements, demo data
CCINNPSQL_IT=1 CCINNPSQL_IT_VERSIONS="9.6,13,17,18" swift test --filter IntegrationTests
scripts/pooler-up.sh                                        # PgBouncer (transaction pooling) + Pgpool-II in front of PG 17
CCINNPSQL_IT=1 CCINNPSQL_IT_POOLERS=1 swift test --filter PoolerIntegrationTests
scripts/extensions-up.sh                                    # TimescaleDB, Citus and PostGIS single-node servers
CCINNPSQL_IT=1 CCINNPSQL_IT_EXTENSIONS=1 swift test --filter ExtensionIntegrationTests
scripts/pg-down.sh                                          # removes every ccinnpsql-it-* container
```

Containers are named `ccinnpsql-it-*`, bound to `127.0.0.1` on ports 15400–15499 and capped at 256 MB. PostgreSQL images come from
the public ECR mirror of the Docker official images (`public.ecr.aws/docker/library/postgres`), so pulling all versions does not
hit Docker Hub's rate limit; override with `CCINNPSQL_IT_REGISTRY`. The PostGIS checks use the community multi-arch build
`imresamu/postgis` (the official image is amd64-only) — for tests only. The MCP subprocess test needs `swift build` first and uses
the `trust_user` role, so no secret is passed to the subprocess.

`scripts/seed-demo.sql` (all versions) and `scripts/seed-modern.sql` (partitioning, procedures, generated columns where the
version supports them) create the `shop` schema used by the tests and screenshots.

### Running the app against a server directly

```bash
CCINNPSQL_PASSWORD=ccinn dist/CcinnPsql.app/Contents/MacOS/CcinnPsql \
  --connect 127.0.0.1:15417 --user ccinn --database ccinn --object shop.orders --section statistics
```

Passwords never go on the command line; set `CCINNPSQL_PASSWORD` in the environment. Other launch arguments:
`--sql "…" --auto-run [--view chart|plan]`, `--sql "…" --explain [--analyze]`, `--operations activity|locks|replication|…`,
`--notifications`, `--profile <saved name>`, `--appearance light|dark` and
`--snapshot <file.png> --snapshot-delay <seconds> --quit-after-snapshot` (renders the window off-screen without stealing focus
or needing screen-recording permission). `CCINNPSQL_PROFILE_DIR` points the app and the MCP server at another profile folder.

## Project layout

| Module | Responsibility |
|---|---|
| `PostgresWire` | PostgreSQL protocol v3: messages, incremental decoder, MD5/SCRAM-SHA-256, error fields, text/binary value decoding (no I/O) |
| `PostgresKit` | Transport (TLS after SSLRequest, direct TLS, SSH), connection actor, CancelRequest, pools, sessions, listener, pooler detection, catalog/insight/operation APIs |
| `CcinnPsqlKit` | UI-independent app logic: profiles, SQL lexer/splitter/guard/redactor, completion, EXPLAIN model, charts, export, history, MCP |
| `CcinnPsql` | SwiftUI/AppKit application and the `mcp` subcommand |

Dependencies only point downwards; lower modules must not import higher ones.

## Guidelines

- **Test first.** Add or update tests with every behaviour change. Protocol and concurrency logic is covered with the in-memory fake server in `Tests/PostgresKitTests/FakePostgresServer.swift`; PostgreSQL behaviour with the integration suites.
- **Version-aware SQL.** Catalog differences between 9.6 and 18 live in the `CatalogSQL`, `InsightSQL` and `OperationsSQL` builders; read results by column name (`Record.text("name")`), never by position. Fall back only on server errors, never on timeouts or cancellation.
- **Never crash on input.** No force unwraps/casts, unchecked indexing or trapping integer conversions on data that comes from a server, a file or the user. Parsers are fuzzed; keep it that way.
- **Concurrency.** Code must compile in Swift 6 strict-concurrency mode. Keep shared mutable state inside actors or behind small, well-scoped locks; do not block the main actor with I/O, sorting or chart preparation.
- **Secrets** must never appear in logs, errors or files.
- Keep pull requests focused, and update `CHANGELOG.md` under *Unreleased*.

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org/): `feat(scope): …`, `fix(scope): …`, `docs: …`, `test: …`, `refactor: …`, `chore: …`.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make sure `swift build` and `swift test --skip IntegrationTests` pass (and the integration suites, if you touched PostgresKit).
3. Describe what changed and how you tested it (including PostgreSQL versions and poolers, if relevant).

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE). Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).
