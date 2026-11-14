import Foundation

/// Host and port of a PostgreSQL server (or pooler).
public struct Endpoint: Sendable, Hashable, Codable, CustomStringConvertible {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 5432) {
        self.host = host
        self.port = port
    }

    public var isIPv6: Bool { host.contains(":") }
    public var description: String { isIPv6 ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// libpq-compatible `sslmode` values (without `allow`).
public enum SSLMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case disable
    case prefer
    case require
    case verifyCA = "verify-ca"
    case verifyFull = "verify-full"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Disable"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify full"
        }
    }

    public var explanation: String {
        switch self {
        case .disable: "Never encrypt the connection."
        case .prefer: "Encrypt when the server supports TLS; otherwise connect unencrypted."
        case .require: "Always encrypt, without verifying the server certificate."
        case .verifyCA: "Encrypt and verify the certificate chain (system trust store or the CA file)."
        case .verifyFull: "Encrypt, verify the chain and check that the certificate matches the host name."
        }
    }

    public var usesTLS: Bool { self != .disable }
    public var verifiesChain: Bool { self == .verifyCA || self == .verifyFull }
}

/// How TLS is negotiated: PostgreSQL's SSLRequest, or direct TLS with ALPN (PostgreSQL 17+).
public enum SSLNegotiation: String, Sendable, Codable, CaseIterable, Identifiable {
    case postgres
    case direct

    public var id: String { rawValue }
}

/// TLS settings for one connection attempt.
public struct TLSConfiguration: Sendable, Equatable {
    public var mode: SSLMode
    public var negotiation: SSLNegotiation
    /// Name used for SNI and hostname verification (the profile host, also through an SSH tunnel).
    public var serverName: String
    /// PEM file with trusted root certificates; `nil` uses the system trust store.
    public var rootCertificatePath: String?

    public init(mode: SSLMode, negotiation: SSLNegotiation = .postgres, serverName: String, rootCertificatePath: String? = nil) {
        self.mode = mode
        self.negotiation = negotiation
        self.serverName = serverName
        self.rootCertificatePath = rootCertificatePath
    }
}

/// A bidirectional byte stream to one server. `close()` must be safe to call from any thread at any
/// time (it is used for cancellation) and must make pending calls fail promptly.
public protocol ByteTransport: AnyObject, Sendable {
    func send(_ bytes: [UInt8]) async throws
    /// Returns the next chunk of bytes (at least one byte) or throws when the stream ends.
    func receive() async throws -> [UInt8]
    func close()
    /// The address actually connected to (resolved IP), used to pin cancel requests to the same server.
    var remoteEndpoint: Endpoint? { get }
    /// Negotiated TLS protocol, e.g. `TLS 1.3`; `nil` when unencrypted.
    var tlsDescription: String? { get }
}

extension ByteTransport {
    public var remoteEndpoint: Endpoint? { nil }
    public var tlsDescription: String? { nil }
}

public struct TransportOptions: Sendable, Equatable {
    /// Seconds to establish the TCP connection (and TLS handshake).
    public var connectTimeout: Double
    /// TLS to use, `nil` for a plain connection.
    public var tls: TLSConfiguration?

    public init(connectTimeout: Double = 10, tls: TLSConfiguration? = nil) {
        self.connectTimeout = connectTimeout
        self.tls = tls
    }
}

public typealias TransportFactory = @Sendable (Endpoint, TransportOptions) async throws -> any ByteTransport

public enum Transports {
    /// TCP (and TLS) via Network.framework.
    public static let network: TransportFactory = { endpoint, options in
        try await NetworkTransport.connect(to: endpoint, options: options)
    }
}
