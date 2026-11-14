import Foundation
import Testing
@testable import PostgresWire

@Suite("MD5 authentication")
struct MD5AuthenticationTests {
    @Test func knownVectors() {
        #expect(PostgresAuth.md5Response(user: "postgres", password: "postgres", salt: [1, 2, 3, 4]) == "md568be9ed08db75f318087ab337aaea044")
        #expect(PostgresAuth.md5Response(user: "md5_user", password: "md5pass", salt: [0xDE, 0xAD, 0xBE, 0xEF]) == "md5e3b6efe0a52d8f6e17c26ed3b6c5a9fb")
    }
}

@Suite("SCRAM-SHA-256")
struct SCRAMTests {
    // RFC 7677 section 3.
    let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

    @Test func rfc7677Vectors() throws {
        var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        #expect(String(decoding: client.clientFirstMessage(), as: UTF8.self) == "n,,n=user,r=rOprNGfwEbeRWgbNEkqO")
        let final = try client.clientFinalMessage(serverFirst: Array(serverFirst.utf8))
        #expect(String(decoding: final, as: UTF8.self)
            == "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=")
        try client.verifyServerFinal(Array("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8))
        #expect(client.isVerified)
    }

    @Test func postgresUsesAnEmptyUserName() {
        var client = SCRAMSHA256Client(password: "secret", clientNonce: "abc")
        #expect(String(decoding: client.clientFirstMessage(), as: UTF8.self) == "n,,n=,r=abc")
    }

    @Test func generatedNoncesArePrintableAndUnique() {
        var first = SCRAMSHA256Client(password: "x")
        var second = SCRAMSHA256Client(password: "x")
        let a = String(decoding: first.clientFirstMessage(), as: UTF8.self)
        let b = String(decoding: second.clientFirstMessage(), as: UTF8.self)
        #expect(a != b)
        let nonce = a.dropFirst("n,,n=,r=".count)
        #expect(nonce.count >= 24)
        #expect(nonce.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E && $0 != UInt8(ascii: ",") })
    }

    @Test func rejectsWrongServerSignature() throws {
        var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = client.clientFirstMessage()
        _ = try client.clientFinalMessage(serverFirst: Array(serverFirst.utf8))
        #expect(throws: PostgresWireError.self) {
            try client.verifyServerFinal(Array("v=AAAATRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8))
        }
        #expect(!client.isVerified)
    }

    @Test func rejectsServerErrorsAndBadMessages() {
        func attempt(_ message: String) -> Bool {
            var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
            _ = client.clientFirstMessage()
            return (try? client.clientFinalMessage(serverFirst: Array(message.utf8))) == nil
        }
        // Nonce that does not extend ours (replay/impersonation).
        #expect(attempt("r=XXXXX,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        #expect(attempt("r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096")) // no server part
        #expect(attempt("r=rOprNGfwEbeRWgbNEkqOabc,s=!!!,i=4096"))
        #expect(attempt("r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0"))
        #expect(attempt("r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=999999999"))
        #expect(attempt("r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=-5"))
        #expect(attempt("m=ext,r=rOprNGfwEbeRWgbNEkqOabc,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"))
        #expect(attempt("garbage"))
        #expect(attempt(""))

        var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: "rOprNGfwEbeRWgbNEkqO")
        _ = client.clientFirstMessage()
        _ = try? client.clientFinalMessage(serverFirst: Array(serverFirst.utf8))
        #expect(throws: PostgresWireError.self) { try client.verifyServerFinal(Array("e=invalid-proof".utf8)) }
    }

    @Test func finalBeforeFirstIsRejected() {
        var client = SCRAMSHA256Client(password: "pencil", clientNonce: "n")
        #expect(throws: PostgresWireError.self) { try client.verifyServerFinal(Array("v=abc".utf8)) }
    }

    @Test func fuzzedServerMessagesNeverTrap() {
        var generator = SplitMix64(seed: 77)
        let alphabet = Array("rsiv=,abcXYZ012+/!%$\u{0}é".utf8)
        for _ in 0..<5_000 {
            var client = SCRAMSHA256Client(password: "p", clientNonce: "abc")
            _ = client.clientFirstMessage()
            let length = Int(generator.next() % 80)
            var bytes = Array("r=abc".utf8)
            for _ in 0..<length { bytes.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            _ = try? client.clientFinalMessage(serverFirst: bytes)
            _ = try? client.verifyServerFinal(bytes)
        }
    }
}

@Suite("SASLprep")
struct SASLprepTests {
    @Test func asciiIsUnchanged() {
        #expect(SASLprep.prepare("pencil") == "pencil")
        #expect(SASLprep.prepare("p a s s") == "p a s s")
    }

    @Test func mapsSpacesAndRemovesIgnorables() {
        #expect(SASLprep.prepare("a\u{00A0}b") == "a b")
        #expect(SASLprep.prepare("a\u{00AD}b") == "ab")
        #expect(SASLprep.prepare("\u{2168}") == "IX") // NFKC
    }

    @Test func prohibitedInputIsUsedAsIs() {
        #expect(SASLprep.prepare("a\u{0007}b") == "a\u{0007}b")
        #expect(SASLprep.prepare("\u{E000}x") == "\u{E000}x")
    }
}
