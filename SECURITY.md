# Security Policy

## Supported versions

Security fixes are released for the latest minor version of CcinnPsql.

| Version | Supported |
|---|---|
| 1.0.x | ✅ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/whiteCcinn/ccinnpsql/security/advisories/new). Include:

- a description of the issue and its impact,
- steps to reproduce (PostgreSQL version, poolers, connection options, sample data if relevant),
- any suggested fix.

You can expect an acknowledgement within a few days. Once a fix is available, we will publish a release and an advisory crediting the reporter (unless you prefer to remain anonymous).

## Scope and design notes

- Passwords and SSH secrets are stored in the macOS Keychain; saved profiles on disk never contain them. Query history and the MCP audit log redact `PASSWORD '…'`, credential-like options and passwords inside connection strings, and are written with 0600 permissions.
- **TLS:** `sslmode` works like libpq's (`disable`, `prefer`, `require`, `verify-ca`, `verify-full`). The TLS handshake happens on the same socket after PostgreSQL's SSLRequest; bytes the server sends after its `S` answer are handed to TLS, never to the protocol parser (CVE-2021-23222 class). `prefer` silently continues unencrypted when the server has no TLS, exactly like libpq — the workspace header and the MCP `server_info` tool always show whether a connection is encrypted. Use `verify-full` against servers you do not control. TLS 1.2 is the minimum. Client certificates are not supported yet.
- **Authentication:** SCRAM-SHA-256 (the server's signature is verified before the login is accepted, so a server that does not know the password cannot impersonate the real one), MD5 and trust. Clear-text passwords are only sent when explicitly enabled for a connection. GSSAPI/SSPI/Kerberos and SCRAM channel binding (`-PLUS`) are not supported.
- **Cancellation** uses PostgreSQL's CancelRequest on a new connection to the same resolved address (encrypted when the session is). The next statement waits until a cancel has been delivered, so a late cancel never hits a later statement.
- **MCP read-only access** is enforced twice: the app's PostgreSQL lexer rejects anything that is not a single read (writes, data-modifying CTEs, `SELECT … INTO`, `COPY`, `DO`, `CALL`, transaction control, `SET`, row locks, Unicode-escaped identifiers, and functions with side effects such as `pg_terminate_backend`, `set_config`, `pg_notify`, advisory locks, large objects, server file access, replication slots and `dblink`), and the statement then runs through the extended protocol inside `BEGIN TRANSACTION READ ONLY … ROLLBACK` with a statement timeout. Issues that let a read-only MCP connection change data or server state are considered vulnerabilities.
- SSH tunnels use the system `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`: changed host keys are rejected. Secrets reach ssh through a short-lived 0600 file, never through the environment or command line.
- Statements built by the app (metadata, cancel/terminate, materialized-view refresh, LISTEN/NOTIFY) use bound parameters or quote identifiers and literals; issues that allow injecting SQL through object names are considered vulnerabilities.
