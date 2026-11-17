import CcinnPsqlKit
import Foundation
import PostgresKit
import Testing

/// The lexer ends numbers and parameters where each server version does. The formatter re-lexes its output with the same
/// lexer, so a boundary the lexer gets wrong is one its safety check cannot see: the server is the only oracle.
///
/// For every probe, the server's own token boundaries are read from `SELECT <probe>`: a result has one column whose label
/// is the alias split off the literal (`123abc` → `abc` before 15) and whose value is the literal's; an error names the
/// token it failed at (`trailing junk after numeric literal at or near "123abc"`) and its position.
@Suite("Lexer against the server", .enabled(if: IT.enabled), .serialized)
struct LexerIntegrationTests {
    static let probes = [
        "123abc", "123e", "1e", "1e+", "1e+x", "1e5x", "1e+5x", "1E-5", "1.5x", "1.x", "1.e5", "1.e", "1.e+5", "1.5e", ".5x", "1.",
        "0x1F", "0X1f", "0x1Fg", "0x", "0x_1F", "0x1_F", "0x1F_", "0xor", "0x1for", "0xé", "0o17", "0O7", "0o19", "0o8", "0o_7",
        "0b101", "0B1", "0b12", "0b1f", "0b_1", "0bor", "0or", "00", "00x1", "0_1", "0_x1", "1_000", "1_000_000", "1__000", "1_",
        "1_000.5_5", ".5_5", "1e1_0", "1e_10", "1e5_", "1._5", "1_.5", "1_000e3", "1_0or", "1..2", "1...2", "1_0..2", "1.5.5",
        "1e5.5", "0x1F.5", "0x1F.x", ".e5", "123a$b", "123$", "123é", "1e5é", "1as", "a.5 FROM (SELECT 1 a) s", "x..y",
        // Not numbers, same oracle: a whole operator run ("operator too long"), bit strings ending at their first quote.
        "1 " + String(repeating: "@", count: 70) + "-2", "B'10''01'", "X'1F''2E'",
    ]
    /// Positional parameters, probed with `PREPARE … AS SELECT <probe>` and `EXECUTE …(7)`.
    static let parameterProbes = ["$1abc", "$1_0", "$1.5", "$1e5", "$01", "$1x", "$1 abc"]

    private enum Outcome {
        case column(label: String, value: String?)
        /// The token the server failed at and its UTF-16 offset in the statement (`nil` at the end of the input).
        case failure(token: String?, offset: Int?, message: String)
    }

    /// PostgreSQL 15 is between the two syntaxes (junk rejected, no new literals); it is not modelled exactly.
    private func syntax(_ version: String) -> SQLLexer.Syntax? {
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        if major >= 16 { return .postgres16 }
        return major <= 14 ? .postgres14 : nil
    }

    private func outcome(_ session: SQLSession, _ statements: [String], probed statement: String) async -> Outcome {
        do {
            var last: QueryResult?
            for sql in statements { last = try await session.run(sql, mode: .simple) }
            guard let rows = last?.lastRowSet, rows.columns.count == 1 else {
                return .failure(token: nil, offset: nil, message: "expected one column, got \(last?.lastRowSet?.columnNames ?? [])")
            }
            return .column(label: rows.columns[0].name, value: rows.scalar)
        } catch let error as PostgresError {
            let message = error.message
            // `… at or near "TOKEN"` (PostgreSQL quotes the token's text as it was written).
            var token: String?
            if let near = message.range(of: "at or near \""), message.hasSuffix("\"") {
                token = String(message[near.upperBound..<message.index(before: message.endIndex)])
            }
            // `P` counts characters from 1.
            let offset = error.position.flatMap { position -> Int? in
                guard position >= 1, position - 1 <= statement.count else { return nil }
                return statement.index(statement.startIndex, offsetBy: position - 1).utf16Offset(in: statement)
            }
            return .failure(token: token, offset: offset, message: message)
        } catch {
            return .failure(token: nil, offset: nil, message: "\(error)")
        }
    }

    /// The numeric value of a literal as the lexer delimits it.
    private func value(of literal: String) -> Double? {
        let digits = literal.replacingOccurrences(of: "_", with: "")
        let radixes: [String: Int] = ["0x": 16, "0o": 8, "0b": 2]
        if let radix = radixes[String(digits.prefix(2)).lowercased()] { return Int(digits.dropFirst(2), radix: radix).map(Double.init) }
        return Double(digits)
    }

    /// Our tokens of `statement` agree with what the server did with it.
    private func check(_ statement: String, probe: String, prefix: Int, outcome: Outcome, syntax: SQLLexer.Syntax,
                       version: String, parameterValue: String? = nil) {
        let lexer = SQLLexer(statement, syntax: syntax)
        let tokens = lexer.tokens()
        let context = "PostgreSQL \(version): \(statement.debugDescription)"
        switch outcome {
        case let .column(label, value):
            // The probe is a literal, or a literal and the alias the server split off it.
            let probeTokens = tokens.filter { $0.range.lowerBound >= prefix && $0.range.upperBound <= prefix + probe.utf16.count }
            guard let literal = probeTokens.first, probeTokens.count <= 2 else {
                Issue.record("\(context): lexed as \(probeTokens.map { lexer.text(of: $0) }), the server returned one column \(label)")
                return
            }
            #expect(probeTokens.last?.range.upperBound == prefix + probe.utf16.count, "\(context)")
            if probeTokens.count == 2 {
                let alias = probeTokens[1]
                #expect(alias.kind == .identifier || alias.kind == .keyword, "\(context)")
                #expect(lexer.text(of: alias).lowercased() == label, "\(context): alias \(lexer.text(of: alias)), label \(label)")
            } else {
                #expect(label == "?column?", "\(context): one token, but the server named the column \(label)")
            }
            if let parameterValue {
                #expect(literal.kind == .parameter && value == parameterValue, "\(context)")
            } else {
                #expect(literal.kind == .number, "\(context)")
                let ours = self.value(of: lexer.text(of: literal))
                #expect(ours != nil && ours == value.flatMap(Double.init), "\(context): \(lexer.text(of: literal)) vs \(value ?? "NULL")")
            }
        case let .failure(token, offset, message):
            // A syntax error names the token the parser stopped at: ours must start there with the same text.
            guard let token, let offset else { return } // "at end of input", or an error without a token
            let ours = tokens.first { $0.range.lowerBound == offset }
            #expect(ours.map { lexer.text(of: $0) } == token, "\(context): \(message); ours: \(ours.map { lexer.text(of: $0) } ?? "no token there")")
        }
    }

    private func sqlState(_ session: SQLSession, _ sql: String) async -> String? {
        do {
            _ = try await session.run(sql, mode: .simple)
            return nil
        } catch let error as PostgresError {
            return error.sqlState ?? "?"
        } catch {
            return "?"
        }
    }

    private func exists(_ session: SQLSession, _ name: String) async throws -> Bool {
        try await session.run("SELECT to_regclass('\(name)') IS NOT NULL", mode: .simple).lastRowSet?.scalar == "t"
    }

    /// PostgreSQL matches keywords after folding ASCII letters only (downcase_identifier, ScanKeywordLookup): `ınto`,
    /// `exiſts` and `ſelect` are names, so these are syntax errors and create nothing. The formatter treats them as names
    /// on that basis; the read-only guard reads every case mapping and refuses them anyway.
    @Test(arguments: IT.versions)
    func nonASCIISpellingsAreNotKeywords(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        let name = "ccinn_fold_\(UInt32.random(in: 0...UInt32.max))"
        for sql in ["select 1 ınto \(name)", "create table if not exiſts \(name) (a int)", "ſelect 1 into \(name)"] {
            #expect(await sqlState(session, sql) == "42601", "PostgreSQL \(version): \(sql)")
            #expect(try await !exists(session, name), "PostgreSQL \(version): \(sql) created \(name)")
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            for syntax in SQLLexer.Syntax.servers {
                let lexer = SQLLexer(sql, syntax: syntax)
                let nonASCII = lexer.tokens().filter { lexer.units[$0.range].contains { $0 >= 0x80 } }
                #expect(nonASCII.allSatisfy { $0.kind == .identifier }, "\(sql)")
            }
        }
        // The control: spelled in ASCII, INTO does create the table.
        #expect(await sqlState(session, "select 1 into \(name)") == nil)
        #expect(try await exists(session, name))
        _ = try await session.run("DROP TABLE \(name)", mode: .simple)
        await session.close()
        await client.close()
    }

    /// `SELECT 1.5into t`: before 15 the number and INTO are two tokens and the statement creates table t; from 15 on it is
    /// trailing junk. The guard refuses it on every version, and a READ ONLY transaction refuses it too.
    @Test(arguments: IT.versions)
    func aNumberGluedToIntoCreatesATableOnlyBefore15(version: String) async throws {
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        let major = Int(version.split(separator: ".").first ?? "") ?? 0
        for literal in ["1.5", "1", "1e2"] {
            let name = "ccinn_into_\(UInt32.random(in: 0...UInt32.max))"
            let sql = "SELECT \(literal)into \(name)"
            #expect(ReadOnlySQLGuard.check(sql) != nil, "\(sql)")
            let state = await sqlState(session, sql)
            if major <= 14 {
                #expect(state == nil, "PostgreSQL \(version): \(sql)")
                #expect(try await exists(session, name), "PostgreSQL \(version) creates the table")
                _ = try await session.run("DROP TABLE \(name)", mode: .simple)
            } else {
                #expect(state == "42601", "PostgreSQL \(version): \(sql)")
                #expect(try await !exists(session, name))
            }
            let readOnly = await sqlState(session, "BEGIN TRANSACTION READ ONLY; \(sql)")
            _ = try? await session.run("ROLLBACK", mode: .simple)
            #expect(readOnly == (major <= 14 ? "25006" : "42601"), "PostgreSQL \(version): READ ONLY \(sql)")
        }
        await session.close()
        await client.close()
    }

    @Test(arguments: IT.versions)
    func numbersEndWhereTheServerEndsThem(version: String) async throws {
        guard let syntax = syntax(version) else { return }
        let client = try await PostgresClient.connect(IT.configuration(version))
        let session = client.openSession()
        for probe in Self.probes {
            let statement = "SELECT " + probe
            let outcome = await outcome(session, [statement], probed: statement)
            check(statement, probe: probe, prefix: 7, outcome: outcome, syntax: syntax, version: version)
        }
        for probe in Self.parameterProbes {
            let prepare = "PREPARE ccinn_probe(int) AS SELECT " + probe
            let outcome = await outcome(session, [prepare, "EXECUTE ccinn_probe(7)"], probed: prepare)
            _ = try? await session.run("DEALLOCATE ALL", mode: .simple)
            check(prepare, probe: probe, prefix: prepare.utf16.count - probe.utf16.count, outcome: outcome, syntax: syntax,
                  version: version, parameterValue: "7")
        }
        await session.close()
        await client.close()
    }
}
