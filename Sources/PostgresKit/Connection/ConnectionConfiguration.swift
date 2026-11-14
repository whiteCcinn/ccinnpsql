import Foundation

/// Everything needed to open one authenticated session to a PostgreSQL server (or pooler).
public struct ConnectionConfiguration: Sendable, Equatable {
    public var endpoint: Endpoint
    public var username: String
    public var password: String
    /// Database to connect to (PostgreSQL connections are bound to one database); defaults to the user name.
    public var database: String
    public var applicationName: String
    public var connectTimeout: Double
    public var sslMode: SSLMode
    public var sslNegotiation: SSLNegotiation
    /// PEM file of trusted roots for verify-ca / verify-full.
    public var rootCertificatePath: String?
    /// Host name used for TLS SNI and verification; stays the profile host when `endpoint` is an SSH tunnel.
    public var tlsServerName: String
    /// Allows answering a clear-text password request. Only sensible over TLS or an SSH tunnel.
    public var allowCleartextPassword: Bool
    /// Upper bound for one backend message (protects memory from hostile servers).
    public var maxMessageSize: Int

    public init(endpoint: Endpoint, username: String, password: String = "", database: String? = nil,
                applicationName: String = "CcinnPsql", connectTimeout: Double = 10, sslMode: SSLMode = .prefer,
                sslNegotiation: SSLNegotiation = .postgres, rootCertificatePath: String? = nil, tlsServerName: String? = nil,
                allowCleartextPassword: Bool = false, maxMessageSize: Int = 1 << 30 + 1 << 20) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        let trimmedDatabase = database?.trimmingCharacters(in: .whitespaces) ?? ""
        self.database = trimmedDatabase.isEmpty ? username : trimmedDatabase
        self.applicationName = applicationName
        self.connectTimeout = connectTimeout
        self.sslMode = sslMode
        self.sslNegotiation = sslNegotiation
        self.rootCertificatePath = rootCertificatePath
        self.tlsServerName = tlsServerName ?? endpoint.host
        self.allowCleartextPassword = allowCleartextPassword
        self.maxMessageSize = maxMessageSize
    }

    /// Same configuration pointed at another endpoint (SSH tunnels); TLS still verifies the original host.
    public func with(endpoint newEndpoint: Endpoint) -> ConnectionConfiguration {
        var copy = self
        copy.endpoint = newEndpoint
        return copy
    }

    /// Same configuration for another database.
    public func with(database newDatabase: String) -> ConnectionConfiguration {
        var copy = self
        let trimmed = newDatabase.trimmingCharacters(in: .whitespaces)
        copy.database = trimmed.isEmpty ? username : trimmed
        return copy
    }

    /// Startup parameters. Only ones PgBouncer tracks or accepts are sent (no `options`, no `extra_float_digits`).
    var startupParameters: [(String, String)] {
        [("user", username), ("database", database), ("application_name", String(applicationName.prefix(63))),
         ("client_encoding", "UTF8"), ("DateStyle", "ISO")]
    }

    func tlsConfiguration(mode: SSLMode) -> TLSConfiguration? {
        guard mode.usesTLS else { return nil }
        // Direct TLS needs a mode that never falls back to clear text (as libpq).
        let negotiation: SSLNegotiation = sslNegotiation == .direct && mode != .prefer ? .direct : .postgres
        return TLSConfiguration(mode: mode, negotiation: negotiation, serverName: tlsServerName, rootCertificatePath: rootCertificatePath)
    }
}
