import Foundation
import Testing
@testable import PostgresWire

/// Builds a backend message the way a server would frame it.
func backend(_ type: Character, _ body: [UInt8]) -> [UInt8] {
    var writer = ByteWriter()
    writer.writeUInt8(UInt8(ascii: type.unicodeScalars.first!))
    writer.writeInt32(Int32(body.count + 4))
    writer.writeBytes(body)
    return writer.bytes
}

func cstring(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }

func int16(_ value: Int16) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
func int32(_ value: Int32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
func int64(_ value: Int64) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }

@Suite("Byte reader and writer")
struct ByteReaderTests {
    @Test func readsBigEndianIntegersAndStrings() throws {
        var reader = ByteReader([0x00, 0x01, 0xFF, 0xFF, 0xFF, 0xFE, 0x41, 0x42, 0x00, 0x07])
        #expect(try reader.readInt16() == 1)
        #expect(try reader.readInt32() == -2)
        #expect(try reader.readCString() == "AB")
        #expect(try reader.readUInt8() == 7)
        #expect(reader.isAtEnd)
    }

    @Test func throwsInsteadOfTrappingOnShortInput() {
        var reader = ByteReader([0x00])
        #expect(throws: PostgresWireError.self) { try reader.readInt32() }
        var unterminated = ByteReader(Array("abc".utf8))
        #expect(throws: PostgresWireError.self) { try unterminated.readCString() }
        var negative = ByteReader([0x01])
        #expect(throws: PostgresWireError.self) { try negative.readBytes(-1) }
    }

    @Test func writerProducesNetworkOrder() {
        var writer = ByteWriter()
        writer.writeInt16(-1)
        writer.writeInt32(196_608)
        writer.writeCString("x")
        #expect(writer.bytes == [0xFF, 0xFF, 0x00, 0x03, 0x00, 0x00, 0x78, 0x00])
    }
}

@Suite("Frontend messages")
struct FrontendMessageTests {
    @Test func startupMessageHasProtocol30AndParameters() throws {
        let bytes = FrontendMessage.startup(parameters: [("user", "alice"), ("database", "db")])
        var reader = ByteReader(bytes)
        #expect(try reader.readInt32() == Int32(bytes.count))
        #expect(try reader.readInt32() == 196_608)
        #expect(try reader.readCString() == "user")
        #expect(try reader.readCString() == "alice")
        #expect(try reader.readCString() == "database")
        #expect(try reader.readCString() == "db")
        #expect(try reader.readUInt8() == 0)
        #expect(reader.isAtEnd)
    }

    @Test func startupDropsNulBytesFromParameters() throws {
        let bytes = FrontendMessage.startup(parameters: [("user", "a\0b")])
        var reader = ByteReader(Array(bytes.dropFirst(8)))
        #expect(try reader.readCString() == "user")
        #expect(try reader.readCString() == "ab")
    }

    @Test func sslRequestAndCancelRequest() throws {
        #expect(FrontendMessage.sslRequest == [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F])
        let cancel = FrontendMessage.cancelRequest(processID: 4242, secretKey: [1, 2, 3, 4])
        #expect(cancel == [0, 0, 0, 16, 0x04, 0xD2, 0x16, 0x2E] + int32(4242) + [1, 2, 3, 4])
    }

    @Test func queryMessage() {
        #expect(FrontendMessage.query("SELECT 1") == [UInt8(ascii: "Q")] + int32(13) + cstring("SELECT 1"))
    }

    @Test func extendedQuerySequence() throws {
        let parse = FrontendMessage.parse(statement: "", query: "SELECT $1::int", parameterTypes: [23])
        // Built step by step: one long `+` chain is too slow for older type checkers (Swift 6.2 in CI).
        let parseLength: Int32 = 4 + 1 + 15 + 2 + 4
        var expectedParse: [UInt8] = [UInt8(ascii: "P")]
        expectedParse.append(contentsOf: int32(parseLength))
        expectedParse.append(0)
        expectedParse.append(contentsOf: cstring("SELECT $1::int"))
        expectedParse.append(contentsOf: int16(1))
        expectedParse.append(contentsOf: int32(23))
        #expect(parse == expectedParse)

        let bind = FrontendMessage.bind(portal: "", statement: "", parameters: [.text("42"), .null, .binary([1])], resultFormats: [.binary])
        var reader = ByteReader(Array(bind.dropFirst(5)))
        #expect(bind.first == UInt8(ascii: "B"))
        #expect(try reader.readCString() == "")
        #expect(try reader.readCString() == "")
        #expect(try reader.readInt16() == 3) // parameter format codes
        #expect(try reader.readInt16() == 0)
        #expect(try reader.readInt16() == 0)
        #expect(try reader.readInt16() == 1)
        #expect(try reader.readInt16() == 3) // parameter values
        #expect(try reader.readInt32() == 2)
        #expect(Array(try reader.readBytes(2)) == Array("42".utf8))
        #expect(try reader.readInt32() == -1)
        #expect(try reader.readInt32() == 1)
        #expect(Array(try reader.readBytes(1)) == [1])
        #expect(try reader.readInt16() == 1)
        #expect(try reader.readInt16() == 1)
        #expect(reader.isAtEnd)

        #expect(FrontendMessage.describe(.portal, name: "") == [UInt8(ascii: "D")] + int32(6) + [UInt8(ascii: "P"), 0])
        #expect(FrontendMessage.execute(portal: "", maxRows: 0) == [UInt8(ascii: "E")] + int32(9) + [0] + int32(0))
        #expect(FrontendMessage.sync == [UInt8(ascii: "S"), 0, 0, 0, 4])
        #expect(FrontendMessage.flush == [UInt8(ascii: "H"), 0, 0, 0, 4])
        #expect(FrontendMessage.terminate == [UInt8(ascii: "X"), 0, 0, 0, 4])
    }

    @Test func saslMessages() throws {
        let initial = FrontendMessage.saslInitialResponse(mechanism: "SCRAM-SHA-256", data: Array("n,,n=,r=abc".utf8))
        var reader = ByteReader(Array(initial.dropFirst(5)))
        #expect(initial.first == UInt8(ascii: "p"))
        #expect(try reader.readCString() == "SCRAM-SHA-256")
        #expect(try reader.readInt32() == 11)
        #expect(Array(try reader.readBytes(11)) == Array("n,,n=,r=abc".utf8))
        #expect(FrontendMessage.saslResponse([9, 8]) == [UInt8(ascii: "p")] + int32(6) + [9, 8])
        #expect(FrontendMessage.copyFail("no") == [UInt8(ascii: "f")] + int32(7) + cstring("no"))
    }
}

@Suite("Backend message decoder")
struct MessageDecoderTests {
    @Test func reassemblesMessagesAcrossChunks() throws {
        let stream = backend("Z", [UInt8(ascii: "I")]) + backend("S", cstring("server_version") + cstring("17.2"))
        var decoder = MessageDecoder()
        var messages: [BackendMessage] = []
        for byte in stream {
            decoder.append([byte])
            while let message = try decoder.next() { messages.append(try message.parse()) }
        }
        #expect(messages.count == 2)
        guard case .readyForQuery(.idle) = messages[0] else { Issue.record("expected ReadyForQuery"); return }
        guard case let .parameterStatus(name, value) = messages[1] else { Issue.record("expected ParameterStatus"); return }
        #expect(name == "server_version")
        #expect(value == "17.2")
    }

    @Test func rejectsInvalidAndOversizedLengths() {
        var tooShort = MessageDecoder()
        tooShort.append([UInt8(ascii: "Z"), 0, 0, 0, 3])
        #expect(throws: PostgresWireError.self) { _ = try tooShort.next() }

        var oversized = MessageDecoder(maxMessageSize: 1024)
        oversized.append([UInt8(ascii: "D"), 0x00, 0x10, 0x00, 0x00])
        #expect(throws: PostgresWireError.self) { _ = try oversized.next() }
    }

    @Test func compactsConsumedBytes() throws {
        var decoder = MessageDecoder()
        let message = backend("D", int16(1) + int32(3) + Array("abc".utf8))
        for _ in 0..<50_000 {
            decoder.append(message)
            _ = try decoder.next()
        }
        #expect(decoder.bufferedByteCount < 128 * 1024)
    }

    @Test func parsesEveryKnownMessage() throws {
        func parse(_ bytes: [UInt8]) throws -> BackendMessage {
            var decoder = MessageDecoder()
            decoder.append(bytes)
            guard let raw = try decoder.next() else { throw PostgresWireError.truncated("test") }
            return try raw.parse()
        }
        guard case .authentication(.ok) = try parse(backend("R", int32(0))) else { Issue.record("auth ok"); return }
        guard case let .authentication(.md5Password(salt)) = try parse(backend("R", int32(5) + [1, 2, 3, 4])), salt == [1, 2, 3, 4] else {
            Issue.record("md5"); return
        }
        guard case let .authentication(.sasl(mechanisms)) = try parse(backend("R", int32(10) + cstring("SCRAM-SHA-256-PLUS") + cstring("SCRAM-SHA-256") + [0])),
              mechanisms == ["SCRAM-SHA-256-PLUS", "SCRAM-SHA-256"] else { Issue.record("sasl"); return }
        guard case let .authentication(.saslContinue(data)) = try parse(backend("R", int32(11) + [7, 7])), data == [7, 7] else { Issue.record("cont"); return }
        guard case .authentication(.unsupported(7)) = try parse(backend("R", int32(7))) else { Issue.record("gss"); return }
        guard case let .backendKeyData(pid, key) = try parse(backend("K", int32(77) + int32(-5))), pid == 77, key == int32(-5) else {
            Issue.record("key"); return
        }
        guard case .readyForQuery(.inTransaction) = try parse(backend("Z", [UInt8(ascii: "T")])) else { Issue.record("T"); return }
        guard case .readyForQuery(.failedTransaction) = try parse(backend("Z", [UInt8(ascii: "E")])) else { Issue.record("E"); return }
        guard case let .commandComplete(tag) = try parse(backend("C", cstring("INSERT 0 3"))), tag == "INSERT 0 3" else { Issue.record("C"); return }
        guard case .emptyQueryResponse = try parse(backend("I", [])) else { Issue.record("I"); return }
        guard case .parseComplete = try parse(backend("1", [])) else { Issue.record("1"); return }
        guard case .bindComplete = try parse(backend("2", [])) else { Issue.record("2"); return }
        guard case .closeComplete = try parse(backend("3", [])) else { Issue.record("3"); return }
        guard case .noData = try parse(backend("n", [])) else { Issue.record("n"); return }
        guard case .portalSuspended = try parse(backend("s", [])) else { Issue.record("s"); return }
        guard case let .parameterDescription(types) = try parse(backend("t", int16(2) + int32(23) + int32(25))), types == [23, 25] else {
            Issue.record("t"); return
        }
        guard case let .notification(note) = try parse(backend("A", int32(9) + cstring("jobs") + cstring("done"))),
              note.processID == 9, note.channel == "jobs", note.payload == "done" else { Issue.record("A"); return }
        guard case let .copyOutResponse(format) = try parse(backend("H", [0] + int16(2) + int16(0) + int16(0))),
              format.isBinary == false, format.columnFormats.count == 2 else { Issue.record("H"); return }
        guard case .copyInResponse = try parse(backend("G", [0] + int16(0))) else { Issue.record("G"); return }
        guard case let .copyData(data) = try parse(backend("d", [1, 2])), Array(data) == [1, 2] else { Issue.record("d"); return }
        guard case .copyDone = try parse(backend("c", [])) else { Issue.record("c"); return }
        guard case let .negotiateProtocolVersion(minor, options) = try parse(backend("v", int32(0) + int32(1) + cstring("_pq_.x"))),
              minor == 0, options == ["_pq_.x"] else { Issue.record("v"); return }
        guard case .unknown(UInt8(ascii: "?")) = try parse(backend("?", [])) else { Issue.record("unknown"); return }
    }

    @Test func rowDescriptionAndDataRow() throws {
        let description = int16(2)
            + cstring("id") + int32(16_384) + int16(1) + int32(23) + int16(4) + int32(-1) + int16(0)
            + cstring("name") + int32(0) + int16(0) + int32(25) + int16(-1) + int32(-1) + int16(1)
        var decoder = MessageDecoder()
        decoder.append(backend("T", description))
        guard let raw = try decoder.next(), case let .rowDescription(fields) = try raw.parse() else { Issue.record("T"); return }
        #expect(fields.count == 2)
        #expect(fields[0].name == "id")
        #expect(fields[0].tableOID == 16_384)
        #expect(fields[0].columnNumber == 1)
        #expect(fields[0].typeOID == 23)
        #expect(fields[1].format == .binary)

        let cells = try DataRow.cells(int16(3) + int32(2) + Array("42".utf8) + int32(-1) + int32(0))
        #expect(cells.count == 3)
        #expect(cells[0].map(Array.init) == Array("42".utf8))
        #expect(cells[1] == nil)
        #expect(cells[2].map(Array.init) == [])
    }

    @Test func dataRowRejectsLiesAboutLengths() {
        #expect(throws: PostgresWireError.self) { _ = try DataRow.cells(int16(1) + int32(10) + [1, 2]) }
        #expect(throws: PostgresWireError.self) { _ = try DataRow.cells(int16(-1)) }
        #expect(throws: PostgresWireError.self) { _ = try DataRow.cells(int16(1) + int32(-7)) }
    }

    @Test func errorResponseFields() throws {
        let body = [UInt8(ascii: "S")] + cstring("ERROR") + [UInt8(ascii: "V")] + cstring("ERROR")
            + [UInt8(ascii: "C")] + cstring("42P01") + [UInt8(ascii: "M")] + cstring("relation \"nope\" does not exist")
            + [UInt8(ascii: "P")] + cstring("15") + [UInt8(ascii: "H")] + cstring("Check the name.")
            + [UInt8(ascii: "q")] + cstring("SELECT 1") + [UInt8(ascii: "p")] + cstring("3") + [UInt8(ascii: "W")] + cstring("PL/pgSQL function f()")
            + [UInt8(ascii: "s")] + cstring("public") + [UInt8(ascii: "t")] + cstring("t") + [UInt8(ascii: "n")] + cstring("t_pkey") + [0]
        var decoder = MessageDecoder()
        decoder.append(backend("E", body))
        guard let raw = try decoder.next(), case let .errorResponse(fields) = try raw.parse() else { Issue.record("E"); return }
        #expect(fields.severity == "ERROR")
        #expect(fields.sqlState == "42P01")
        #expect(fields.message == "relation \"nope\" does not exist")
        #expect(fields.position == 15)
        #expect(fields.hint == "Check the name.")
        #expect(fields.internalQuery == "SELECT 1")
        #expect(fields.internalPosition == 3)
        #expect(fields.whereContext == "PL/pgSQL function f()")
        #expect(fields.schemaName == "public")
        #expect(fields.tableName == "t")
        #expect(fields.constraintName == "t_pkey")
    }

    @Test func errorPositionRejectsGarbage() throws {
        let body = [UInt8(ascii: "P")] + cstring("99999999999999999999") + [UInt8(ascii: "M")] + cstring("x") + [0]
        var decoder = MessageDecoder()
        decoder.append(backend("E", body))
        guard let raw = try decoder.next(), case let .errorResponse(fields) = try raw.parse() else { Issue.record("E"); return }
        #expect(fields.position == nil)
    }
}

@Suite("Command tags")
struct CommandTagTests {
    @Test func parsesRowCounts() {
        #expect(CommandTag("INSERT 0 5").rowCount == 5)
        #expect(CommandTag("INSERT 0 5").verb == "INSERT")
        #expect(CommandTag("UPDATE 3").rowCount == 3)
        #expect(CommandTag("DELETE 0").rowCount == 0)
        #expect(CommandTag("SELECT 12").rowCount == 12)
        #expect(CommandTag("COPY 7").rowCount == 7)
        #expect(CommandTag("MERGE 2").rowCount == 2)
        #expect(CommandTag("CREATE TABLE").rowCount == nil)
        #expect(CommandTag("CREATE TABLE").verb == "CREATE TABLE")
        #expect(CommandTag("UPDATE 99999999999999999999999").rowCount == nil)
    }
}

@Suite("Fuzzing")
struct WireFuzzTests {
    @Test func randomAndMutatedInputNeverTraps() {
        var generator = SplitMix64(seed: 0xC0FFEE)
        let types: [UInt8] = Array("RKSZTDCIEN123ntsAGHWdcvV?".utf8)
        let seeds: [[UInt8]] = [
            backend("T", int16(1) + cstring("a") + int32(0) + int16(0) + int32(23) + int16(4) + int32(-1) + int16(0)),
            backend("E", [UInt8(ascii: "M")] + cstring("x") + [0]),
            backend("R", int32(10) + cstring("SCRAM-SHA-256") + [0]),
            backend("A", int32(1) + cstring("c") + cstring("p")),
            backend("H", [0] + int16(1) + int16(0)),
        ]
        for iteration in 0..<20_000 {
            var bytes: [UInt8]
            if iteration % 2 == 0 {
                let length = Int(generator.next() % 64)
                var body: [UInt8] = []
                for _ in 0..<length { body.append(UInt8(truncatingIfNeeded: generator.next())) }
                bytes = backend(Character(UnicodeScalar(types[Int(generator.next() % UInt64(types.count))])), body)
            } else {
                bytes = seeds[Int(generator.next() % UInt64(seeds.count))]
                let flips = 1 + Int(generator.next() % 4)
                for _ in 0..<flips where !bytes.isEmpty {
                    bytes[Int(generator.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: generator.next())
                }
                if generator.next() % 3 == 0 { bytes = Array(bytes.prefix(Int(generator.next() % UInt64(bytes.count + 1)))) }
            }
            var decoder = MessageDecoder(maxMessageSize: 4096)
            decoder.append(bytes)
            while true {
                guard let raw = try? decoder.next() else { break }
                _ = try? raw.parse()
                if raw.type == UInt8(ascii: "D") { _ = try? DataRow.cells(raw.payload) }
            }
        }
    }
}

/// Deterministic PRNG for reproducible fuzzing.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
