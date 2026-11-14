import Foundation
import Network
import Security

/// Names a server certificate is issued for: subjectAltName dNSName / iPAddress entries and the subject's
/// commonName attributes. Parsed from DER without I/O; malformed input yields `nil`, never a trap.
public struct X509Names: Sendable, Equatable {
    public var dnsNames: [String] = []
    public var ipAddresses: [[UInt8]] = []
    public var commonNames: [String] = []

    /// Parses an X.509 certificate (DER).
    public init?(der: [UInt8]) {
        var outer = DERReader(der)
        guard let certificate = outer.read(tag: 0x30) else { return nil }
        var certificateReader = DERReader(der, range: certificate)
        guard let tbs = certificateReader.read(tag: 0x30) else { return nil }
        var fields = DERReader(der, range: tbs)
        if fields.peekTag == 0xA0 { _ = fields.read(tag: 0xA0) } // version
        guard fields.read(tag: 0x02) != nil, // serialNumber
              fields.read(tag: 0x30) != nil, // signature algorithm
              fields.read(tag: 0x30) != nil, // issuer
              fields.read(tag: 0x30) != nil, // validity
              let subject = fields.read(tag: 0x30),
              fields.read(tag: 0x30) != nil // subjectPublicKeyInfo
        else { return nil }
        guard let commonNames = Self.commonNames(der, subject) else { return nil }
        self.commonNames = commonNames
        while !fields.isAtEnd {
            guard let (tag, content) = fields.readAny() else { return nil }
            guard tag == 0xA3 else { continue } // issuerUniqueID [1], subjectUniqueID [2]
            var explicit = DERReader(der, range: content)
            guard let list = explicit.read(tag: 0x30) else { return nil }
            var extensions = DERReader(der, range: list)
            while !extensions.isAtEnd {
                guard let element = extensions.read(tag: 0x30) else { return nil }
                var fieldsOfExtension = DERReader(der, range: element)
                guard let oid = fieldsOfExtension.read(tag: 0x06) else { return nil }
                if fieldsOfExtension.peekTag == 0x01 { _ = fieldsOfExtension.read(tag: 0x01) } // critical
                guard let value = fieldsOfExtension.read(tag: 0x04) else { return nil }
                if Array(der[oid]) == Self.subjectAltNameOID, !parseAltNames(der, value) { return nil }
            }
        }
    }

    public init(dnsNames: [String] = [], ipAddresses: [[UInt8]] = [], commonNames: [String] = []) {
        self.dnsNames = dnsNames
        self.ipAddresses = ipAddresses
        self.commonNames = commonNames
    }

    static let subjectAltNameOID: [UInt8] = [0x55, 0x1D, 0x11] // 2.5.29.17
    static let commonNameOID: [UInt8] = [0x55, 0x04, 0x03] // 2.5.4.3

    private mutating func parseAltNames(_ der: [UInt8], _ value: Range<Int>) -> Bool {
        var octets = DERReader(der, range: value)
        guard let sequence = octets.read(tag: 0x30) else { return false }
        var names = DERReader(der, range: sequence)
        while !names.isAtEnd {
            guard let (tag, content) = names.readAny() else { return false }
            switch tag {
            case 0x82: // [2] dNSName, IA5String
                dnsNames.append(String(decoding: der[content], as: UTF8.self))
            case 0x87: // [7] iPAddress, 4 or 16 octets
                ipAddresses.append(Array(der[content]))
            default:
                continue
            }
        }
        return true
    }

    private static func commonNames(_ der: [UInt8], _ subject: Range<Int>) -> [String]? {
        var result: [String] = []
        var rdns = DERReader(der, range: subject)
        while !rdns.isAtEnd {
            guard let set = rdns.read(tag: 0x31) else { return nil }
            var attributes = DERReader(der, range: set)
            while !attributes.isAtEnd {
                guard let attribute = attributes.read(tag: 0x30) else { return nil }
                var pair = DERReader(der, range: attribute)
                guard let oid = pair.read(tag: 0x06), let (tag, value) = pair.readAny() else { return nil }
                guard Array(der[oid]) == commonNameOID else { continue }
                result.append(decodeString(tag: tag, Array(der[value])))
            }
        }
        return result
    }

    private static func decodeString(tag: UInt8, _ bytes: [UInt8]) -> String {
        switch tag {
        case 0x1E: // BMPString, UTF-16BE
            var units: [UInt16] = []
            var index = 0
            while index + 1 < bytes.count {
                units.append(UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        case 0x14: // T61String: treat as Latin-1
            return String(bytes.map { Character(Unicode.Scalar($0)) })
        default: // UTF8String, PrintableString, IA5String
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// Bounds-checked DER element reader (definite lengths up to 4 length octets).
struct DERReader {
    private let bytes: [UInt8]
    private var index: Int
    private let end: Int

    init(_ bytes: [UInt8], range: Range<Int>? = nil) {
        self.bytes = bytes
        let bounds = range ?? 0..<bytes.count
        index = max(0, min(bounds.lowerBound, bytes.count))
        end = max(index, min(bounds.upperBound, bytes.count))
    }

    var isAtEnd: Bool { index >= end }
    var peekTag: UInt8? { index < end ? bytes[index] : nil }

    mutating func read(tag expected: UInt8) -> Range<Int>? {
        guard peekTag == expected, let (_, content) = readAny() else { return nil }
        return content
    }

    mutating func readAny() -> (UInt8, Range<Int>)? {
        guard index + 2 <= end else { return nil }
        let tag = bytes[index]
        guard tag & 0x1F != 0x1F else { return nil } // high tag numbers do not occur in certificates
        var cursor = index + 1
        let first = bytes[cursor]
        cursor += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let octets = Int(first & 0x7F)
            guard (1...4).contains(octets), cursor + octets <= end else { return nil }
            for _ in 0..<octets {
                length = length << 8 | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, length <= end - cursor else { return nil }
        index = cursor + length
        return (tag, cursor..<(cursor + length))
    }
}

/// Host-name check of `sslmode=verify-full`, following libpq: subjectAltName dNSName entries (a leading `*.`
/// wildcard matches one label) and iPAddress entries; the commonName is used only when the certificate has no
/// subjectAltName of the host's kind (DNS name or IP address).
public enum HostNameMatcher {
    public static func matches(host rawHost: String, names: X509Names) -> Bool {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        guard !host.isEmpty else { return false }
        let address = ipAddress(host)
        if names.dnsNames.contains(where: { nameMatches(pattern: $0, host: host) }) { return true }
        if let address, names.ipAddresses.contains(address) { return true }
        let checkCommonName = address == nil ? names.dnsNames.isEmpty : names.ipAddresses.isEmpty
        return checkCommonName && names.commonNames.contains { nameMatches(pattern: $0, host: host) }
    }

    static func nameMatches(pattern rawPattern: String, host: String) -> Bool {
        let pattern = rawPattern.lowercased()
        guard !pattern.isEmpty, !pattern.contains("\0") else { return false }
        if pattern == host { return true }
        guard pattern.hasPrefix("*."), pattern.count > 2 else { return false }
        let suffix = pattern.dropFirst() // ".example.com"
        guard host.count > suffix.count, host.hasSuffix(suffix) else { return false }
        let label = host.dropLast(suffix.count)
        return !label.isEmpty && !label.contains(".")
    }

    static func ipAddress(_ host: String) -> [UInt8]? {
        if let v4 = IPv4Address(host) { return [UInt8](v4.rawValue) }
        let unscoped = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if let v6 = IPv6Address(unscoped) { return [UInt8](v6.rawValue) }
        return nil
    }
}

/// Server-certificate verification for `verify-ca` / `verify-full`. Trust is evaluated with the basic X.509
/// policy (chain, signatures, validity dates), not Apple's TLS server policy: that one also enforces web-PKI
/// rules (at most 825/398 days of validity, serverAuth EKU, SAN required) that libpq does not, and which common
/// private-CA PostgreSQL certificates fail. The host name is then checked like libpq does.
public enum PeerCertificateVerifier {
    public enum Failure: Error, Equatable, Sendable {
        case untrusted(String)
        case hostMismatch(host: String, names: [String])
        case unreadableCertificate

        public var message: String {
            switch self {
            case let .untrusted(reason): "the server certificate is not trusted: \(reason)"
            case let .hostMismatch(host, names):
                "the server certificate does not match “\(host)” (it is issued for \(names.isEmpty ? "no host name" : names.prefix(8).joined(separator: ", ")))"
            case .unreadableCertificate: "the server certificate could not be read"
            }
        }
    }

    /// Evaluates `trust` (the peer's chain). `anchors` replaces the system roots when given; `hostName` turns on
    /// the verify-full name check; `date` pins the evaluation time (tests).
    public static func evaluate(_ trust: SecTrust, anchors: [SecCertificate]?, hostName: String?, date: Date? = nil) -> Result<Void, Failure> {
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        if let anchors {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        if let date { SecTrustSetVerifyDate(trust, date as CFDate) }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let reason = error.map { CFErrorCopyDescription($0) as String } ?? "unknown reason"
            return .failure(.untrusted(reason))
        }
        guard let hostName else { return .success(()) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              let names = X509Names(der: [UInt8](SecCertificateCopyData(leaf) as Data))
        else { return .failure(.unreadableCertificate) }
        guard HostNameMatcher.matches(host: hostName, names: names) else {
            let listed = names.dnsNames + names.ipAddresses.map(Self.format) + (names.dnsNames.isEmpty ? names.commonNames : [])
            return .failure(.hostMismatch(host: hostName, names: listed))
        }
        return .success(())
    }

    static func format(_ address: [UInt8]) -> String {
        if address.count == 4, let v4 = IPv4Address(Data(address)) { return "\(v4)" }
        if address.count == 16, let v6 = IPv6Address(Data(address)) { return "\(v6)" }
        return address.map { String(format: "%02x", $0) }.joined()
    }
}
