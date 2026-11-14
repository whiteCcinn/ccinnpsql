import Foundation
import Security
import Testing
@testable import PostgresKit

private func certificate(_ base64: String) throws -> SecCertificate {
    let data = try #require(Data(base64Encoded: base64))
    return try #require(SecCertificateCreateWithData(nil, data as CFData))
}

private func der(_ base64: String) -> [UInt8] { [UInt8](Data(base64Encoded: base64) ?? Data()) }

/// Inside every test certificate's validity window, so results do not depend on the day the tests run.
private let evaluationDate = ISO8601DateFormatter().date(from: "2028-06-01T00:00:00Z") ?? Date()

/// `nil` when the certificate is accepted.
private func verify(_ leaf: String, host: String?, date: Date = evaluationDate) throws -> PeerCertificateVerifier.Failure? {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates([try certificate(leaf)] as CFArray, SecPolicyCreateBasicX509(), &trust)
    #expect(status == errSecSuccess)
    let created = try #require(trust)
    switch PeerCertificateVerifier.evaluate(created, anchors: [try certificate(TestCertificates.ca)], hostName: host, date: date) {
    case .success: return nil
    case let .failure(failure): return failure
    }
}

/// Review finding 4: verify-ca / verify-full must accept ordinary private-CA PostgreSQL certificates (long
/// validity, CN only, no EKU) like libpq, and still reject untrusted chains and wrong host names.
@Suite("Certificate verification")
struct CertificateVerificationTests {
    @Test func parsesSubjectAltNamesAndCommonName() throws {
        let names = try #require(X509Names(der: der(TestCertificates.san)))
        #expect(names.dnsNames == ["db.example.test", "*.pg.example.test"])
        #expect(names.ipAddresses == [[127, 0, 0, 1], [UInt8](repeating: 0, count: 15) + [1]])
        #expect(names.commonNames == ["ignored.example.test"])
        let commonOnly = try #require(X509Names(der: der(TestCertificates.cn)))
        #expect(commonOnly.dnsNames.isEmpty && commonOnly.ipAddresses.isEmpty)
        #expect(commonOnly.commonNames == ["cnonly.example.test"])
    }

    @Test func longLivedPrivateCACertificatesAreTrusted() throws {
        #expect(try verify(TestCertificates.san, host: nil) == nil)            // verify-ca
        #expect(try verify(TestCertificates.cn, host: nil) == nil)
        #expect(try verify(TestCertificates.san, host: "db.example.test") == nil) // verify-full
        #expect(try verify(TestCertificates.san, host: "DB.Example.Test") == nil)
        #expect(try verify(TestCertificates.san, host: "replica1.pg.example.test") == nil)
        #expect(try verify(TestCertificates.san, host: "127.0.0.1") == nil)
        #expect(try verify(TestCertificates.san, host: "::1") == nil)
        #expect(try verify(TestCertificates.san, host: "[::1]") == nil)
        #expect(try verify(TestCertificates.cn, host: "cnonly.example.test") == nil)
    }

    @Test func wrongHostsAndForeignChainsAreRejected() throws {
        // The CN is ignored when DNS SANs exist (RFC 6125, libpq).
        guard case .hostMismatch(_, let names)? = try verify(TestCertificates.san, host: "ignored.example.test") else {
            Issue.record("CN accepted despite SAN")
            return
        }
        #expect(names.contains("db.example.test") && names.contains("127.0.0.1"))
        // A wildcard matches exactly one label.
        #expect(try verify(TestCertificates.san, host: "a.b.pg.example.test") != nil)
        #expect(try verify(TestCertificates.san, host: "pg.example.test") != nil)
        #expect(try verify(TestCertificates.san, host: "127.0.0.2") != nil)
        #expect(try verify(TestCertificates.cn, host: "other.example.test") != nil)
        // Signed by an unrelated CA, expired, or not yet valid.
        guard case .untrusted? = try verify(TestCertificates.rogue, host: "db.example.test") else {
            Issue.record("foreign chain accepted")
            return
        }
        let later = ISO8601DateFormatter().date(from: "2040-01-01T00:00:00Z") ?? Date()
        #expect(try verify(TestCertificates.san, host: nil, date: later) != nil)
        let earlier = ISO8601DateFormatter().date(from: "2020-01-01T00:00:00Z") ?? Date()
        #expect(try verify(TestCertificates.san, host: nil, date: earlier) != nil)
    }

    @Test func hostNameRulesFollowLibpq() {
        let dnsOnly = X509Names(dnsNames: ["*.example.com"], commonNames: ["127.0.0.1"])
        #expect(HostNameMatcher.matches(host: "db.example.com", names: dnsOnly))
        #expect(!HostNameMatcher.matches(host: ".example.com", names: dnsOnly))
        #expect(!HostNameMatcher.matches(host: "example.com", names: dnsOnly))
        // An IP host without iPAddress SANs falls back to the CN (libpq compares it as text).
        #expect(HostNameMatcher.matches(host: "127.0.0.1", names: dnsOnly))
        let withAddress = X509Names(ipAddresses: [[10, 0, 0, 1]], commonNames: ["127.0.0.1"])
        #expect(!HostNameMatcher.matches(host: "127.0.0.1", names: withAddress))
        #expect(HostNameMatcher.matches(host: "10.0.0.1", names: withAddress))
        #expect(!HostNameMatcher.matches(host: "", names: X509Names(commonNames: [""])))
        #expect(!HostNameMatcher.matches(host: "x", names: X509Names(commonNames: ["*."])))
        #expect(!HostNameMatcher.matches(host: "a\u{0}b", names: X509Names(commonNames: ["a\u{0}b"])))
    }

    @Test func malformedDERNeverTraps() {
        let valid = der(TestCertificates.san)
        #expect(X509Names(der: []) == nil)
        #expect(X509Names(der: [0x30, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]) == nil)
        for length in stride(from: 0, to: valid.count, by: 7) { _ = X509Names(der: Array(valid.prefix(length))) }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            var mutated = valid
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                mutated[Int.random(in: 0..<mutated.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = X509Names(der: mutated)
        }
        for _ in 0..<500 {
            _ = X509Names(der: (0..<Int.random(in: 0...300, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        }
    }
}
