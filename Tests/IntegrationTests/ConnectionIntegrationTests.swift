import Foundation
import PostgresKit
import PostgresWire
import Testing

/// Integration tests against Docker containers started by `scripts/pg-up.sh` (run with `CCINNPSQL_IT=1`).
/// `CCINNPSQL_IT_VERSIONS` lists the versions to test (default `17`); ports follow `scripts/pg-up.sh`.
enum IT {
    static let enabled = ProcessInfo.processInfo.environment["CCINNPSQL_IT"] == "1"

    static var versions: [String] {
        let raw = ProcessInfo.processInfo.environment["CCINNPSQL_IT_VERSIONS"] ?? "17"
        return raw.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    static func port(_ version: String) -> Int {
        version == "9.6" ? 15496 : 15400 + (Int(version.split(separator: ".").first ?? "17") ?? 17)
    }

    static var caPath: String {
        let base = ProcessInfo.processInfo.environment["CCINNPSQL_IT_DIR"]
            ?? (ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/ccinnpsql-it"
        return (base as NSString).appendingPathComponent("certs/ca.crt")
    }

    static func configuration(_ version: String, user: String = "ccinn", password: String = "ccinn", database: String = "ccinn",
                              sslMode: SSLMode = .prefer) -> ConnectionConfiguration {
        ConnectionConfiguration(endpoint: Endpoint(host: "127.0.0.1", port: port(version)), username: user, password: password,
                                database: database, connectTimeout: 10, sslMode: sslMode)
    }

    static func connect(_ version: String, user: String = "ccinn", password: String = "ccinn",
                        sslMode: SSLMode = .prefer) async throws -> PostgresConnection {
        try await PostgresConnection.connect(configuration(version, user: user, password: password, sslMode: sslMode))
    }
}

@Suite("Connection integration", .enabled(if: IT.enabled), .serialized)
struct ConnectionIntegrationTests {
    @Test(arguments: IT.versions)
    func authenticationMethods(version: String) async throws {
        let scram = try await IT.connect(version)
        #expect(scram.backendKey != nil)
        #expect(scram.startupParameters["server_version"] != nil)
        #expect(scram.tlsDescription != nil) // prefer → TLS on these servers
        await scram.close()

        let md5 = try await IT.connect(version, user: "md5_user", password: "md5pass", sslMode: .disable)
        #expect(md5.tlsDescription == nil)
        await md5.close()

        let trust = try await IT.connect(version, user: "trust_user", password: "", sslMode: .disable)
        await trust.close()

        await #expect(throws: PostgresError.self) {
            _ = try await IT.connect(version, user: "clear_user", password: "clearpass", sslMode: .disable)
        }
        var clear = IT.configuration(version, user: "clear_user", password: "clearpass", sslMode: .require)
        clear.allowCleartextPassword = true
        let cleartext = try await PostgresConnection.connect(clear)
        await cleartext.close()

        do {
            _ = try await IT.connect(version, password: "wrong", sslMode: .disable)
            Issue.record("wrong password accepted")
        } catch let error as PostgresError {
            #expect(error.kind == .authentication)
            #expect(error.sqlState == "28P01")
        }
    }

    @Test(arguments: IT.versions)
    func tlsModes(version: String) async throws {
        // hostssl-only user: plain connections are rejected, TLS works on the same socket.
        await #expect(throws: PostgresError.self) {
            _ = try await IT.connect(version, user: "tls_user", password: "tlspass", sslMode: .disable)
        }
        let required = try await IT.connect(version, user: "tls_user", password: "tlspass", sslMode: .require)
        #expect(required.tlsDescription?.hasPrefix("TLS 1.") == true)
        await required.close()

        var verified = IT.configuration(version, sslMode: .verifyFull)
        verified.rootCertificatePath = IT.caPath
        verified.tlsServerName = "localhost"
        let full = try await PostgresConnection.connect(verified)
        await full.close()

        // The test certificate is valid for 10 years and has no extendedKeyUsage (review finding 4): verify-full
        // also matches the IP address SAN when the host is 127.0.0.1.
        verified.tlsServerName = "127.0.0.1"
        let byAddress = try await PostgresConnection.connect(verified)
        await byAddress.close()
        var caOnly = IT.configuration(version, sslMode: .verifyCA)
        caOnly.rootCertificatePath = IT.caPath
        let chainOnly = try await PostgresConnection.connect(caOnly)
        await chainOnly.close()

        verified.tlsServerName = "wrong.example.com"
        do {
            _ = try await PostgresConnection.connect(verified)
            Issue.record("hostname mismatch accepted")
        } catch let error as PostgresError {
            #expect(error.kind == .tls)
            #expect(error.message.contains("does not match “wrong.example.com”"), "\(error.message)")
            #expect(error.message.contains("localhost"))
        }

        var untrusted = IT.configuration(version, sslMode: .verifyCA)
        untrusted.rootCertificatePath = nil // system trust store does not know the test CA
        await #expect(throws: PostgresError.self) { _ = try await PostgresConnection.connect(untrusted) }
    }

    @Test(arguments: IT.versions)
    func simpleQueryReturnsEveryResult(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        _ = try await connection.simpleQuery("CREATE TEMP TABLE multi(x int); INSERT INTO multi VALUES (1),(2),(3)")
        let result = try await connection.simpleQuery("SELECT 1 AS one; SELECT 'a' AS a, 'b' AS b; UPDATE multi SET x = x + 1")
        #expect(result.results.count == 3)
        #expect(result.results[0].scalar == "1")
        #expect(result.results[1].columnNames == ["a", "b"])
        #expect(result.results[2].hasRowSet == false)
        #expect(result.results[2].affectedRows == 3)
        #expect(result.transactionStatus == .idle)
    }

    @Test(arguments: IT.versions)
    func binaryAndTextAgree(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        _ = try await connection.simpleQuery("SET TimeZone = 'Asia/Kolkata'")
        let sql = """
        SELECT true AS b, 32767::int2 AS i2, (-2147483648)::int4 AS i4, 9223372036854775807::int8 AS i8,
               1.5::float4 AS f4, 0.1::float8 AS f8, 1e300::float8 AS big, 'NaN'::float8 AS nan,
               123456.789000::numeric AS n, (-0.00001)::numeric(10,6) AS small, 'NaN'::numeric AS nn,
               'héllo'::text AS t, 'x'::varchar(5) AS v, 'pad'::char(5) AS c, '\\xdead00'::bytea AS bin,
               'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u, '2024-02-29'::date AS d, 'infinity'::date AS dinf,
               '13:45:01.25'::time AS tm, '13:45:01+05:30'::timetz AS ttz,
               '2024-02-29 13:45:01.123456'::timestamp AS ts, '2024-02-29 13:45:01.5+00'::timestamptz AS tstz,
               '0044-03-15 12:00:00 BC'::timestamp AS bc,
               '1 year 2 mons 3 days 04:05:06.789'::interval AS iv, '-1 days +02:00:00'::interval AS iv2,
               '{"a": [1, 2]}'::jsonb AS jb, '{"a":1}'::json AS js, '192.168.1.10'::inet AS ip, '10.0.0.0/8'::cidr AS net,
               '2001:db8::1/64'::inet AS ip6, '08:00:2b:01:02:03'::macaddr AS mac, 'pg_class'::name AS nm, 26::oid AS o
        """
        let text = try await connection.extendedQuery(sql, resultFormat: .text)
        let binary = try await connection.extendedQuery(sql, resultFormat: .binaryWhereSupported)
        let textRow = try #require(text.lastRowSet?.rows.first)
        let binaryRow = try #require(binary.lastRowSet?.rows.first)
        let names = text.lastRowSet?.columnNames ?? []
        #expect(binary.lastRowSet?.columns.allSatisfy { $0.format == .binary } == true)
        for (index, name) in names.enumerated() {
            #expect(binaryRow[index] == textRow[index], "\(name): binary \(binaryRow[index] ?? "NULL") vs text \(textRow[index] ?? "NULL")")
        }
    }

    @Test(arguments: IT.versions)
    func errorsCarryFieldsAndKeepTheConnection(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        do {
            _ = try await connection.extendedQuery("SELECT 'é', missing_column FROM pg_class")
            Issue.record("expected an error")
        } catch let error as PostgresError {
            #expect(error.kind == .server)
            #expect(error.sqlState == "42703")
            #expect(error.position == 13) // characters, not bytes
        }
        #expect(try await connection.extendedQuery("SELECT 42").lastRowSet?.scalar == "42")
        // Errors inside an explicit transaction leave it aborted until ROLLBACK.
        _ = try await connection.simpleQuery("BEGIN")
        await #expect(throws: PostgresError.self) { _ = try await connection.simpleQuery("SELECT 1/0") }
        #expect(await connection.transactionStatus == .failedTransaction)
        _ = try await connection.simpleQuery("ROLLBACK")
        #expect(await connection.transactionStatus == .idle)
    }

    @Test(arguments: IT.versions)
    func cancellationKeepsTheSession(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        let started = ContinuousClock.now
        let task = Task { try await connection.extendedQuery("SELECT pg_sleep(30)") }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch let error as PostgresError {
            #expect(error.kind == .cancelled)
        }
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(await connection.isBroken == false)
        // The next statement must not be hit by the earlier cancel.
        for _ in 0..<5 {
            #expect(try await connection.extendedQuery("SELECT pg_sleep(0.05), 1").lastRowSet?.rows.first?[1] == "1")
        }
    }

    @Test(arguments: IT.versions)
    func rowLimits(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        let extended = try await connection.extendedQuery("SELECT g FROM generate_series(1, 100000) g", limits: RowLimits(maxRows: 10))
        #expect(extended.lastRowSet?.rows.count == 10)
        #expect(extended.lastRowSet?.isTruncated == true)
        let exact = try await connection.extendedQuery("SELECT g FROM generate_series(1, 10) g", limits: RowLimits(maxRows: 10))
        #expect(exact.lastRowSet?.isTruncated == false)
        // Review finding 5: past the limit rows are skipped, so the rest of the batch runs and commits.
        let simple = try await connection.simpleQuery("""
            CREATE TEMP TABLE kept(x int); INSERT INTO kept VALUES (1);
            SELECT g FROM generate_series(1, 200000) g;
            INSERT INTO kept VALUES (2)
            """, limits: RowLimits(maxRows: 100))
        #expect(simple.results[2].rows.count == 100)
        #expect(simple.results[2].isTruncated == true)
        #expect(simple.completedStatements == 4)
        #expect(!simple.cancelledAtRowLimit)
        #expect(try await connection.extendedQuery("SELECT count(*) FROM kept").lastRowSet?.scalar == "2")

        // A drain over budget is cancelled, and the result says the batch's uncommitted work was rolled back.
        let cancelled = try await connection.simpleQuery("""
            CREATE TEMP TABLE rolled(x int); INSERT INTO rolled VALUES (1);
            SELECT g FROM generate_series(1, 5000000) g
            """, limits: RowLimits(maxRows: 100, drainRows: 1_000))
        #expect(cancelled.cancelledAtRowLimit)
        #expect(cancelled.lastRowSet?.rows.count == 100)
        #expect(cancelled.notices.last?.severity == "WARNING")
        #expect(cancelled.notices.last?.message.contains("rolled back") == true)
        #expect(try await connection.extendedQuery("SELECT to_regclass('pg_temp.rolled') IS NULL").lastRowSet?.scalar == "t")

        // Inside an explicit transaction the cancel aborts it, and the warning says so.
        _ = try await connection.simpleQuery("BEGIN")
        let aborted = try await connection.simpleQuery("SELECT g FROM generate_series(1, 5000000) g", limits: RowLimits(maxRows: 10, drainRows: 1_000))
        #expect(aborted.transactionStatus == .failedTransaction)
        #expect(aborted.notices.last?.message.contains("ROLLBACK") == true)
        _ = try await connection.simpleQuery("ROLLBACK")

        #expect(await connection.isBroken == false)
        #expect(try await connection.extendedQuery("SELECT 7").lastRowSet?.scalar == "7")
    }

    @Test(arguments: IT.versions)
    func noticesNotificationsAndCopy(version: String) async throws {
        let connection = try await IT.connect(version)
        defer { Task { await connection.close() } }
        let notice = try await connection.simpleQuery("DO $$ BEGIN RAISE NOTICE 'hello %', 42; END $$")
        #expect(notice.notices.first?.message == "hello 42")
        #expect(notice.notices.first?.severity == "NOTICE")

        _ = try await connection.simpleQuery("LISTEN jobs")
        let other = try await IT.connect(version)
        _ = try await other.simpleQuery("NOTIFY jobs, 'done'")
        await other.close()
        try await Task.sleep(for: .milliseconds(200))
        let after = try await connection.simpleQuery("SELECT 1")
        #expect(after.notifications.first?.channel == "jobs")
        #expect(after.notifications.first?.payload == "done")

        let collected = CopyCollector()
        let tag = try await connection.copyOut("COPY (SELECT g, 'x' || g FROM generate_series(1, 3) g) TO STDOUT WITH (FORMAT csv, HEADER)") { chunk in
            await collected.append(chunk)
        }
        #expect(tag?.rowCount == 3)
        #expect(await collected.text == "g,?column?\n1,x1\n2,x2\n3,x3\n")

        // COPY FROM STDIN is refused cleanly and the session stays usable.
        _ = try await connection.simpleQuery("CREATE TEMP TABLE sink(x int)")
        await #expect(throws: PostgresError.self) { _ = try await connection.simpleQuery("COPY sink FROM STDIN") }
        await #expect(throws: PostgresError.self) { _ = try await connection.extendedQuery("COPY sink FROM STDIN") }
        #expect(try await connection.extendedQuery("SELECT 9").lastRowSet?.scalar == "9")
    }
}

actor CopyCollector {
    private var bytes: [UInt8] = []
    func append(_ chunk: [UInt8]) { bytes += chunk }
    var text: String { String(decoding: bytes, as: UTF8.self) }
}
