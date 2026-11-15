import CryptoKit
import Foundation
import Security

/// Password hashing for the MD5 method.
public enum PostgresAuth {
    /// `md5` + md5(hex(md5(password + user)) + salt).
    public static func md5Response(user: String, password: String, salt: [UInt8]) -> String {
        let inner = hex(Insecure.MD5.hash(data: Data((password + user).utf8)))
        return "md5" + hex(Insecure.MD5.hash(data: Data(inner.utf8) + Data(salt)))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for byte in digest {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Client side of SCRAM-SHA-256 (RFC 5802 / RFC 7677) as used by PostgreSQL: no channel binding
/// (gs2 header `n,,`), and the user name is left empty because the server uses the startup user.
///
/// The server's signature must be verified (`isVerified`) before AuthenticationOk is accepted;
/// otherwise a server that never knew the password could impersonate the real one.
public struct SCRAMSHA256Client: Sendable {
    public static let mechanism = "SCRAM-SHA-256"
    /// Iteration counts above this are refused (a hostile server could otherwise stall the client).
    public static let maxIterations = 1_000_000

    private let username: String
    private let password: [UInt8]
    private let clientNonce: String
    private var clientFirstBare: String?
    private var expectedServerSignature: [UInt8]?
    public private(set) var isVerified = false

    static let gs2Header = "n,,"

    public init(username: String = "", password: String, clientNonce: String? = nil) {
        self.username = username
        self.password = Array(SASLprep.prepare(password).utf8)
        self.clientNonce = clientNonce ?? Self.makeNonce()
    }

    public mutating func clientFirstMessage() -> [UInt8] {
        let bare = "n=\(Self.escape(username)),r=\(clientNonce)"
        clientFirstBare = bare
        return Array((Self.gs2Header + bare).utf8)
    }

    /// Processes server-first-message and returns client-final-message.
    public mutating func clientFinalMessage(serverFirst: [UInt8]) throws -> [UInt8] {
        guard let clientFirstBare else { throw Self.failure("SCRAM exchange out of order") }
        let serverFirstText = String(decoding: serverFirst, as: UTF8.self)
        let attributes = try Self.attributes(serverFirstText)
        guard attributes.first?.key == "r" else { throw Self.failure("SCRAM server-first-message does not start with a nonce") }
        guard let nonce = attributes.first(where: { $0.key == "r" })?.value,
              let saltText = attributes.first(where: { $0.key == "s" })?.value,
              let iterationText = attributes.first(where: { $0.key == "i" })?.value else {
            throw Self.failure("SCRAM server-first-message is incomplete")
        }
        guard nonce.hasPrefix(clientNonce), nonce.utf8.count > clientNonce.utf8.count else {
            throw Self.failure("SCRAM server nonce does not extend the client nonce")
        }
        guard let salt = Data(base64Encoded: saltText), !salt.isEmpty else { throw Self.failure("SCRAM salt is not valid base64") }
        guard iterationText.utf8.count <= 10, let iterations = Int(iterationText), iterations > 0 else {
            throw Self.failure("SCRAM iteration count is invalid")
        }
        guard iterations <= Self.maxIterations else {
            throw Self.failure("The server asked for \(iterations) SCRAM iterations (limit \(Self.maxIterations))")
        }

        let saltedPassword = Self.hi(password: password, salt: [UInt8](salt), iterations: iterations)
        let clientKey = Self.hmac(key: saltedPassword, Array("Client Key".utf8))
        let storedKey = [UInt8](SHA256.hash(data: clientKey))
        let channelBinding = Data(Self.gs2Header.utf8).base64EncodedString()
        let finalWithoutProof = "c=\(channelBinding),r=\(nonce)"
        let authMessage = Array("\(clientFirstBare),\(serverFirstText),\(finalWithoutProof)".utf8)
        let clientSignature = Self.hmac(key: storedKey, authMessage)
        let proof = zip(clientKey, clientSignature).map { $0 ^ $1 }
        let serverKey = Self.hmac(key: saltedPassword, Array("Server Key".utf8))
        expectedServerSignature = Self.hmac(key: serverKey, authMessage)
        return Array("\(finalWithoutProof),p=\(Data(proof).base64EncodedString())".utf8)
    }

    /// Checks server-final-message; throws when the server's proof is wrong or it reports an error.
    public mutating func verifyServerFinal(_ serverFinal: [UInt8]) throws {
        guard let expected = expectedServerSignature else { throw Self.failure("SCRAM exchange out of order") }
        let attributes = try Self.attributes(String(decoding: serverFinal, as: UTF8.self))
        if let error = attributes.first(where: { $0.key == "e" })?.value {
            throw Self.failure("The server rejected SCRAM authentication: \(error)")
        }
        guard let verifier = attributes.first(where: { $0.key == "v" })?.value, let signature = Data(base64Encoded: verifier) else {
            throw Self.failure("SCRAM server-final-message has no verifier")
        }
        guard Self.constantTimeEquals([UInt8](signature), expected) else {
            throw Self.failure("The server's SCRAM signature is wrong; it may not be the server you configured")
        }
        isVerified = true
    }

    // MARK: Primitives

    static func hi(password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var block = [UInt8](HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var result = block
        if iterations > 1 {
            for _ in 1..<iterations {
                block = [UInt8](HMAC<SHA256>.authenticationCode(for: block, using: key))
                for index in result.indices { result[index] ^= block[index] }
            }
        }
        return result
    }

    static func hmac(key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        [UInt8](HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }

    /// `k=v` pairs separated by commas; rejects mandatory extensions (`m=`) and malformed input.
    static func attributes(_ text: String) throws -> [(key: Character, value: String)] {
        guard !text.isEmpty, text.utf8.count <= 16_384 else { throw failure("SCRAM message is empty or too long") }
        var result: [(Character, String)] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard part.count >= 2, let key = part.first, key.isLetter, key.isASCII, part.dropFirst().first == "=" else {
                throw failure("SCRAM message is malformed")
            }
            if key == "m" { throw failure("SCRAM mandatory extensions are not supported") }
            result.append((key, String(part.dropFirst(2))))
        }
        return result
    }

    static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "=", with: "=3D").replacingOccurrences(of: ",", with: "=2C")
    }

    /// 24 random bytes as base64 (printable, no commas).
    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
    }

    static func failure(_ message: String) -> PostgresWireError { .authentication(message) }
}

/// The parts of SASLprep (RFC 4013) PostgreSQL applies to SCRAM passwords. As in PostgreSQL, input
/// that SASLprep would reject is used unchanged.
public enum SASLprep {
    public static func prepare(_ password: String) -> String {
        if password.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return password }
        var mapped = String.UnicodeScalarView()
        for scalar in password.unicodeScalars {
            if isNonASCIISpace(scalar) {
                mapped.append(" ")
            } else if !isMappedToNothing(scalar) {
                mapped.append(scalar)
            }
        }
        let normalized = String(mapped).precomposedStringWithCompatibilityMapping
        if normalized.unicodeScalars.contains(where: isProhibited) { return password }
        // Unassigned code points (RFC 3454 table A.1, Unicode 3.2) and bidi violations make PostgreSQL fall back
        // to the raw password too; normalizing such a password here would make SCRAM fail.
        if password.unicodeScalars.contains(where: isUnassigned) || normalized.unicodeScalars.contains(where: isUnassigned) {
            return password
        }
        if !satisfiesBidiRule(Array(normalized.unicodeScalars)) { return password }
        return normalized
    }

    /// Not assigned in Unicode 3.2, the version SASLprep is defined against.
    static func isUnassigned(_ scalar: Unicode.Scalar) -> Bool {
        guard let age = scalar.properties.age else { return true }
        return age.major > 3 || (age.major == 3 && age.minor > 2)
    }

    /// RFC 3454 section 6: a string with right-to-left characters (table D.1) must not contain left-to-right
    /// ones (table D.2) and must start and end with a right-to-left character.
    static func satisfiesBidiRule(_ scalars: [Unicode.Scalar]) -> Bool {
        guard scalars.contains(where: isRandALCat) else { return true }
        guard let first = scalars.first, let last = scalars.last, isRandALCat(first), isRandALCat(last) else { return false }
        return !scalars.contains(where: isLCat)
    }

    /// Table D.1 (characters with bidi property R or AL).
    static func isRandALCat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x05BE, 0x05C0, 0x05C3, 0x05D0...0x05EA, 0x05F0...0x05F4, 0x061B, 0x061F, 0x0621...0x063A, 0x0640...0x064A,
             0x066D...0x066F, 0x0671...0x06D5, 0x06DD, 0x06E5...0x06E6, 0x06FA...0x06FE, 0x0700...0x070D, 0x0710,
             0x0712...0x072C, 0x0780...0x07A5, 0x07B1, 0x200F, 0xFB1D, 0xFB1F...0xFB28, 0xFB2A...0xFB36, 0xFB38...0xFB3C,
             0xFB3E, 0xFB40...0xFB41, 0xFB43...0xFB44, 0xFB46...0xFBB1, 0xFBD3...0xFD3D, 0xFD50...0xFD8F, 0xFD92...0xFDC7,
             0xFDF0...0xFDFC, 0xFE70...0xFE74, 0xFE76...0xFEFC:
            true
        default:
            false
        }
    }

    /// Table D.2 (bidi property L), approximated from Unicode properties: letters and spacing marks that are not
    /// right-to-left. Nonspacing and enclosing marks (bidi NSM), digits and punctuation are not L.
    static func isLCat(_ scalar: Unicode.Scalar) -> Bool {
        guard !isRandALCat(scalar), scalar.properties.isAlphabetic else { return false }
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return false
        default: return true
        }
    }

    static func isNonASCIISpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00A0, 0x1680, 0x2000...0x200B, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    static func isMappedToNothing(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x1806, 0x180B...0x180D, 0x200B...0x200D, 0x2060, 0xFE00...0xFE0F, 0xFEFF: true
        default: false
        }
    }

    static func isProhibited(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000...0x001F, 0x007F, 0x0080...0x009F, 0x06DD, 0x070F, 0x180E, 0x200C, 0x200D, 0x2028, 0x2029,
             0x2060...0x2063, 0x206A...0x206F, 0xFEFF, 0xFFF9...0xFFFC, 0x1D173...0x1D17A,
             0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD,
             0xFDD0...0xFDEF, 0xFFFE, 0xFFFF, 0xD800...0xDFFF, 0xFFF9...0xFFFD, 0x2FF0...0x2FFB, 0x0340, 0x0341, 0x200E,
             0x200F, 0x202A...0x202E, 0x206A...0x206F, 0xE0001, 0xE0020...0xE007F:
            true
        default:
            scalar.value & 0xFFFE == 0xFFFE
        }
    }
}
