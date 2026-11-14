import Foundation
import PostgresWire

/// PostgreSQL release from `server_version_num` (e.g. 170002 → 17.2, 90624 → 9.6.24).
public struct ServerVersion: Sendable, Comparable, Hashable, CustomStringConvertible {
    public let number: Int

    public init(number: Int) {
        self.number = max(0, number)
    }

    public init(major: Int, minor: Int = 0) {
        number = major >= 10 ? major * 10_000 + minor : major * 10_000 + minor * 100
    }

    /// Parses `server_version` text (`17.2 (Debian …)`, `9.6.24`, `16beta1`, `1.23.1/bouncer`).
    public init?(text: String) {
        let numbers = text.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber || $0 == "." })
            .split(separator: ".").prefix(3).compactMap { Int($0) }
        guard let major = numbers.first else { return nil }
        if major >= 10 {
            self.init(number: major * 10_000 + (numbers.count > 1 ? numbers[1] : 0))
        } else {
            self.init(number: major * 10_000 + (numbers.count > 1 ? numbers[1] : 0) * 100 + (numbers.count > 2 ? numbers[2] : 0))
        }
    }

    /// 9 for 9.6, 17 for 17.2.
    public var major: Int { number / 10_000 }

    /// Display major release (`9.6`, `17`).
    public var majorRelease: String {
        major >= 10 ? String(major) : "\(major).\(number / 100 % 100)"
    }

    public var description: String {
        major >= 10 ? "\(major).\(number % 10_000)" : "\(major).\(number / 100 % 100).\(number % 100)"
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool { lhs.number < rhs.number }

    public func atLeast(_ major: Int, _ minor: Int = 0) -> Bool { self >= ServerVersion(major: major, minor: minor) }
}

/// A connection pooler or proxy between the client and PostgreSQL (design D8).
public enum PoolerKind: Sendable, Equatable {
    case none
    /// PgBouncer's admin console (database `pgbouncer`): only SHOW commands, simple protocol.
    case pgBouncerConsole
    /// A pooler that rewrites backend identities (PgBouncer, Odyssey, RDS Proxy, …).
    case pooler
    case pgpool(version: String)

    public var displayName: String {
        switch self {
        case .none: "Direct"
        case .pgBouncerConsole: "PgBouncer admin console"
        case .pooler: "Connection pooler (PgBouncer or similar)"
        case let .pgpool(version): "Pgpool-II \(version)"
        }
    }
}

/// Whether session state survives between statements.
public enum PoolingMode: String, Sendable, Codable, CaseIterable, Identifiable {
    /// Let the app detect it.
    case auto
    /// No pooler: full session semantics.
    case direct
    /// Session pooling (PgBouncer `pool_mode = session`, Pgpool): session state is kept.
    case session
    /// Transaction pooling: SET, LISTEN, temp tables and prepared statements do not survive between transactions.
    case transaction

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "Detect automatically"
        case .direct: "Direct connection"
        case .session: "Session pooler"
        case .transaction: "Transaction pooler"
        }
    }
}

/// Identifies one PostgreSQL server instance, to make sure cancel/terminate land on the node a session was observed on.
public struct NodeFingerprint: Sendable, Hashable {
    public let postmasterStartMicros: Int64
    public let serverAddress: String
    public let serverPort: Int

    public init(postmasterStartMicros: Int64, serverAddress: String, serverPort: Int) {
        self.postmasterStartMicros = postmasterStartMicros
        self.serverAddress = serverAddress
        self.serverPort = serverPort
    }

    /// SQL that is true only on this node; `$1`, `$2`, `$3` bind the fingerprint (see `bindValues`).
    static let matchCondition = """
        (extract(epoch from pg_postmaster_start_time()) * 1000000)::bigint = $1::bigint \
        AND coalesce(host(inet_server_addr()), '') = $2 AND coalesce(inet_server_port(), 0) = $3::int
        """

    var bindValues: [BindValue] { [.text(String(postmasterStartMicros)), .text(serverAddress), .text(String(serverPort))] }
}

/// An installed extension of the current database.
public struct InstalledExtension: Sendable, Hashable {
    public let name: String
    public let version: String
    public let schema: String

    public init(name: String, version: String, schema: String) {
        self.name = name
        self.version = version
        self.schema = schema
    }
}

/// Facts about the connected server, loaded once per client.
public struct ServerInfo: Sendable {
    /// `version()` (or `server_version` for poolers that answer themselves).
    public let versionString: String
    public let version: ServerVersion
    public let currentUser: String
    public let currentDatabase: String
    public let isSuperuser: Bool
    public let isInRecovery: Bool
    public let node: NodeFingerprint?
    public let extensions: [InstalledExtension]
    public let pooler: PoolerKind
    /// Effective pooling mode after detection and the profile override.
    public let poolingMode: PoolingMode
    /// How the pooling mode was determined, for the UI.
    public let poolingDetail: String
    public let maxConnections: Int?
    public let tlsDescription: String?

    public init(versionString: String, version: ServerVersion, currentUser: String, currentDatabase: String, isSuperuser: Bool,
                isInRecovery: Bool, node: NodeFingerprint?, extensions: [InstalledExtension], pooler: PoolerKind,
                poolingMode: PoolingMode, poolingDetail: String, maxConnections: Int?, tlsDescription: String?) {
        self.versionString = versionString
        self.version = version
        self.currentUser = currentUser
        self.currentDatabase = currentDatabase
        self.isSuperuser = isSuperuser
        self.isInRecovery = isInRecovery
        self.node = node
        self.extensions = extensions
        self.pooler = pooler
        self.poolingMode = poolingMode
        self.poolingDetail = poolingDetail
        self.maxConnections = maxConnections
        self.tlsDescription = tlsDescription
    }

    public func extensionNamed(_ name: String) -> InstalledExtension? { extensions.first { $0.name == name } }
    public var isPgBouncerConsole: Bool { pooler == .pgBouncerConsole }
    /// Session state (SET, LISTEN, temp tables) survives between statements.
    public var keepsSessionState: Bool { poolingMode != .transaction && pooler != .pgBouncerConsole }
    /// Short product line, e.g. `PostgreSQL 17.2` or `PostgreSQL 16.4 · TimescaleDB 2.17`.
    public var productSummary: String {
        if isPgBouncerConsole { return "PgBouncer \(versionString.split(separator: "/").first ?? "")" }
        var parts = ["PostgreSQL \(version)"]
        for name in ["timescaledb", "citus", "postgis"] {
            if let ext = extensionNamed(name) { parts.append("\(Self.extensionTitle(name)) \(ext.version)") }
        }
        return parts.joined(separator: " · ")
    }

    static func extensionTitle(_ name: String) -> String {
        switch name {
        case "timescaledb": "TimescaleDB"
        case "citus": "Citus"
        case "postgis": "PostGIS"
        case "pg_stat_statements": "pg_stat_statements"
        default: name
        }
    }

    /// Prefix that keeps Pgpool-II from load-balancing a statement to a standby.
    public static let noLoadBalance = "/*NO LOAD BALANCE*/ "

    static func load(from connection: PostgresConnection, override: PoolingMode) async throws -> ServerInfo {
        let reported = connection.startupParameters["server_version"] ?? ""
        if reported.hasSuffix("bouncer") {
            return ServerInfo(versionString: reported, version: ServerVersion(text: reported) ?? ServerVersion(number: 0),
                              currentUser: connection.username, currentDatabase: connection.database, isSuperuser: false,
                              isInRecovery: false, node: nil, extensions: [], pooler: .pgBouncerConsole, poolingMode: .transaction,
                              poolingDetail: "PgBouncer admin console (SHOW commands only)", maxConnections: nil,
                              tlsDescription: connection.tlsDescription)
        }
        let facts = try await connection.extendedQuery(noLoadBalance + """
            SELECT version() AS version, current_setting('server_version_num') AS num, current_user AS usr,
                   current_database() AS db, pg_is_in_recovery() AS in_recovery, pg_backend_pid() AS pid,
                   (extract(epoch from pg_postmaster_start_time()) * 1000000)::bigint AS started_us,
                   coalesce(host(inet_server_addr()), '') AS server_addr, coalesce(inet_server_port(), 0) AS server_port,
                   coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) AS superuser,
                   current_setting('max_connections') AS max_connections
            """, limits: .metadata).records.first
        guard let facts else { throw PostgresError(.protocolViolation, "The server returned no server facts") }
        let versionNumber = facts.int("num").map { ServerVersion(number: Int(clamping: $0)) }
            ?? ServerVersion(text: reported) ?? ServerVersion(number: 0)
        let node = facts.int("started_us").map {
            NodeFingerprint(postmasterStartMicros: $0, serverAddress: facts.text("server_addr") ?? "",
                            serverPort: Int(clamping: facts.int("server_port") ?? 0))
        }
        let extensions = try await probe { try await Self.extensions(on: connection) } ?? []

        // Pooler detection (design D8).
        var pooler: PoolerKind = .none
        var detectedMode: PoolingMode = .direct
        var detail = "Direct connection (the backend pid matches the session key)"
        if let poolVersion = try await probe({ try await connection.simpleQuery("SHOW pool_version").lastRowSet?.scalar }), !poolVersion.isEmpty {
            pooler = .pgpool(version: poolVersion)
            detectedMode = .session
            detail = "Pgpool-II detected (SHOW pool_version)"
        } else if let pid = facts.int("pid"), let key = connection.backendKey, Int64(key.processID) != pid {
            pooler = .pooler
            let second = try await probe { try await connection.extendedQuery("SELECT pg_backend_pid()").lastRowSet?.scalar.flatMap { Int64($0) } }
            if let second, second != pid {
                detectedMode = .transaction
                detail = "Pooler detected; consecutive transactions ran on different backends (transaction pooling)"
            } else {
                detectedMode = .transaction
                detail = "Pooler detected (the session key does not match the backend pid); assuming transaction pooling"
            }
        }
        let mode: PoolingMode
        switch override {
        case .auto: mode = detectedMode
        default:
            mode = override
            detail = "Set in the connection settings (\(override.displayName)); detected: \(detail.prefix(1).lowercased() + detail.dropFirst())"
        }
        return ServerInfo(versionString: facts.text("version") ?? reported, version: versionNumber,
                          currentUser: facts.text("usr") ?? connection.username, currentDatabase: facts.text("db") ?? connection.database,
                          isSuperuser: facts.bool("superuser") ?? false, isInRecovery: facts.bool("in_recovery") ?? false, node: node,
                          extensions: extensions, pooler: pooler, poolingMode: mode, poolingDetail: detail,
                          maxConnections: facts.int("max_connections").map { Int(clamping: $0) }, tlsDescription: connection.tlsDescription)
    }

    /// An optional probe: `nil` when the server rejects the statement (unknown parameter, missing privilege);
    /// timeouts, cancellation and connection failures propagate instead of being mistaken for "not supported".
    static func probe<T>(_ body: () async throws -> T?) async throws -> T? {
        do {
            return try await body()
        } catch let error as PostgresError where error.kind == .server {
            return nil
        }
    }

    static func extensions(on connection: PostgresConnection) async throws -> [InstalledExtension] {
        try await connection.extendedQuery("""
            SELECT e.extname, e.extversion, n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace ORDER BY 1
            """, limits: .metadata).records.compactMap { row in
            guard let name = row.text("extname") else { return nil }
            return InstalledExtension(name: name, version: row.text("extversion") ?? "", schema: row.text("nspname") ?? "public")
        }
    }
}
