import Foundation
import os
import PostgresWire

/// Entry point for one PostgreSQL server: a bounded connection pool per database (created lazily),
/// server facts, and the catalog / insight / operation APIs (see the `PostgresClient+*.swift` extensions).
public final class PostgresClient: Sendable {
    /// The profile's configuration (original host, default database).
    public let configuration: ConnectionConfiguration
    public let serverInfo: ServerInfo
    /// Configuration actually dialled (points at the tunnel's local port when tunnelled).
    let effectiveConfiguration: ConnectionConfiguration
    let transportFactory: TransportFactory
    private let tunnel: SSHTunnel?
    private let poolSize: Int
    private let pools: OSAllocatedUnfairLock<[String: ConnectionPool]>
    /// Type names by (database, OID); user types have per-database OIDs, built-in ones are shared.
    private let typeNames = OSAllocatedUnfairLock<[TypeNameKey: String]>(initialState: [:])
    /// Pools kept open for databases other than the default one.
    static let maxPools = 6

    /// Default per-statement budget for metadata queries issued by the app itself.
    public static let metadataTimeout: Double = 30
    /// How long a metadata query may wait for a table lock (catalog functions such as `pg_get_indexdef` and the
    /// size functions take AccessShareLock, which queues behind DDL): fail fast instead of stalling the UI.
    public static let metadataLockTimeout: Double = 5

    private init(configuration: ConnectionConfiguration, effectiveConfiguration: ConnectionConfiguration, serverInfo: ServerInfo,
                 pool: ConnectionPool, poolSize: Int, transportFactory: @escaping TransportFactory, tunnel: SSHTunnel?) {
        self.configuration = configuration
        self.effectiveConfiguration = effectiveConfiguration
        self.serverInfo = serverInfo
        self.poolSize = poolSize
        self.transportFactory = transportFactory
        self.tunnel = tunnel
        pools = OSAllocatedUnfairLock(initialState: [effectiveConfiguration.database: pool])
    }

    /// Opens the default database's pool and validates the credentials with a first connection.
    /// The client takes ownership of `tunnel` and closes it in `close()`.
    public static func connect(_ configuration: ConnectionConfiguration, poolSize: Int = 4, poolingMode: PoolingMode = .auto,
                               tunnel: SSHTunnel? = nil,
                               transportFactory: @escaping TransportFactory = Transports.network) async throws -> PostgresClient {
        let effective = tunnel.map { configuration.with(endpoint: $0.localAddress) } ?? configuration
        let pool = Self.makePool(effective, poolSize: poolSize, transportFactory: transportFactory)
        do {
            // A pooler can accept the login and then queue every query; bound the facts like any other statement.
            let budget = Self.serverFactsTimeout(configuration)
            let info = try await Deadline.run(seconds: budget, timeoutError: {
                PostgresError(.timeout, "The server accepted the login but did not answer within \(Int(budget)) s (a connection pooler without a free server connection?)")
            }, {
                try await pool.withConnection { connection in
                    try await ServerInfo.load(from: connection, override: poolingMode)
                }
            })
            return PostgresClient(configuration: configuration, effectiveConfiguration: effective, serverInfo: info, pool: pool,
                                  poolSize: poolSize, transportFactory: transportFactory, tunnel: tunnel)
        } catch {
            await pool.close()
            tunnel?.close()
            throw error
        }
    }

    /// Time allowed for loading server facts after the login: twice the connect timeout, at least 5 s.
    static func serverFactsTimeout(_ configuration: ConnectionConfiguration) -> Double {
        max(5, configuration.connectTimeout * 2)
    }

    private static func makePool(_ configuration: ConnectionConfiguration, poolSize: Int,
                                 transportFactory: @escaping TransportFactory) -> ConnectionPool {
        ConnectionPool(maxSize: poolSize) { [configuration] in
            try await PostgresConnection.connect(configuration, transportFactory: transportFactory)
        }
    }

    public func close() async {
        let all = pools.withLock { pools -> [ConnectionPool] in
            defer { pools.removeAll() }
            return Array(pools.values)
        }
        for pool in all { await pool.close() }
        tunnel?.close()
    }

    public var isTunnelled: Bool { tunnel != nil }
    public var defaultDatabase: String { configuration.database }

    /// The pool for `database` (default database when nil), created on first use. Least-recently created
    /// pools beyond `maxPools` are closed (their checked-out connections finish first).
    func pool(for database: String?) -> ConnectionPool {
        let name = database?.isEmpty == false ? database ?? effectiveConfiguration.database : effectiveConfiguration.database
        let defaultName = effectiveConfiguration.database
        let (pool, evicted) = pools.withLock { pools -> (ConnectionPool, [ConnectionPool]) in
            if let existing = pools[name] { return (existing, []) }
            let created = Self.makePool(effectiveConfiguration.with(database: name), poolSize: max(1, poolSize / 2),
                                        transportFactory: transportFactory)
            pools[name] = created
            var removed: [ConnectionPool] = []
            while pools.count > Self.maxPools, let victim = pools.keys.first(where: { $0 != name && $0 != defaultName }) {
                if let pool = pools.removeValue(forKey: victim) { removed.append(pool) }
            }
            return (created, removed)
        }
        for victim in evicted { Task { await victim.close() } }
        return pool
    }

    // MARK: Statements

    /// Runs one statement through the extended protocol on a pooled connection. On timeout or cancellation the
    /// statement is cancelled with a CancelRequest; the connection returns to the pool when the server confirmed.
    public func query(_ sql: String, _ parameters: [BindValue] = [], database: String? = nil, resultFormat: ResultFormat = .text,
                      limits: RowLimits = .metadata, timeout: Double? = PostgresClient.metadataTimeout,
                      lockTimeout: Double? = PostgresClient.metadataLockTimeout) async throws -> QueryResult {
        let lockTimeout = serverInfo.isPgBouncerConsole ? nil : lockTimeout
        return try await pool(for: database).withConnection { connection in
            try await Self.withTimeout(timeout) {
                try await connection.extendedQuery(sql, parameters: parameters, resultFormat: resultFormat, limits: limits, lockTimeout: lockTimeout)
            }
        }
    }

    /// Runs `body` with an exclusively checked-out pooled connection of `database`. A connection left inside a
    /// transaction or broken is not reused.
    public func withConnection<T: Sendable>(database: String? = nil, _ body: (PostgresConnection) async throws -> T) async throws -> T {
        try await pool(for: database).withConnection(body)
    }

    /// Records of the last row set of `sql` (metadata helper).
    public func records(_ sql: String, _ parameters: [BindValue] = [], database: String? = nil,
                        timeout: Double? = PostgresClient.metadataTimeout,
                        lockTimeout: Double? = PostgresClient.metadataLockTimeout) async throws -> [Record] {
        try await query(sql, parameters, database: database, timeout: timeout, lockTimeout: lockTimeout).records
    }

    /// Simple-protocol batch on a pooled connection (scripts, PgBouncer console).
    public func simpleQuery(_ sql: String, database: String? = nil, limits: RowLimits = .metadata,
                            timeout: Double? = PostgresClient.metadataTimeout) async throws -> QueryResult {
        try await pool(for: database).withConnection { connection in
            try await Self.withTimeout(timeout) {
                try await connection.simpleQuery(sql, limits: limits)
            }
        }
    }

    /// Streams `COPY … TO STDOUT` on a dedicated connection (exports must not occupy a pool slot for minutes).
    public func copyOut(_ sql: String, database: String? = nil, sink: @escaping @Sendable ([UInt8]) async throws -> Void) async throws -> CommandTag? {
        let connection = try await makeConnection(database: database)
        do {
            let tag = try await connection.copyOut(sql, sink: sink)
            await connection.close()
            return tag
        } catch {
            await connection.close()
            throw error
        }
    }

    /// Opens a dedicated session (keeps SET/LISTEN state) for an editor tab.
    public func openSession(database: String? = nil) -> SQLSession {
        SQLSession(client: self, database: database?.isEmpty == false ? database ?? defaultDatabase : effectiveConfiguration.database)
    }

    /// A new connection outside the pools (sessions, listeners, exports, operations on other nodes).
    public func makeConnection(database: String? = nil) async throws -> PostgresConnection {
        if Task.isCancelled { throw PostgresError.cancelled() }
        let target = database?.isEmpty == false ? effectiveConfiguration.with(database: database ?? "") : effectiveConfiguration
        return try await PostgresConnection.connect(target, transportFactory: transportFactory)
    }

    /// Prefix for statements that must run on the primary behind Pgpool-II.
    public var routingPrefix: String {
        if case .pgpool = serverInfo.pooler { return ServerInfo.noLoadBalance }
        return ""
    }

    static func withTimeout<T: Sendable>(_ timeout: Double?, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let timeout else { return try await operation() }
        return try await Deadline.run(seconds: timeout, timeoutError: {
            PostgresError(.timeout, "The statement did not finish within \(Int(timeout))s and was cancelled")
        }, operation)
    }

    // MARK: Type names

    /// Fills in names of non-built-in column types (enums, domains, PostGIS types) from `pg_type`, cached per
    /// database. Pass the connection that produced `result` when the caller already holds a pooled connection:
    /// checking out a second one from the same (possibly one-connection) pool would wait for itself.
    public func resolvingTypeNames(_ result: QueryResult, database: String?,
                                   using connection: PostgresConnection? = nil) async throws -> QueryResult {
        let unknown = Set(result.results.flatMap(\.columns).filter { $0.typeName == nil }.map(\.typeOID))
        guard !unknown.isEmpty, !serverInfo.isPgBouncerConsole else { return result }
        let databaseName = database?.isEmpty == false ? database ?? defaultDatabase : effectiveConfiguration.database
        var known: [UInt32: String] = typeNames.withLock { cache in
            var cached: [UInt32: String] = [:]
            for oid in unknown {
                if let name = cache[TypeNameKey(oid: oid, database: databaseName)] { cached[oid] = name }
            }
            return cached
        }
        let missing = unknown.filter { known[$0] == nil }
        if !missing.isEmpty {
            let parameters: [BindValue] = [.text("{" + missing.sorted().map(String.init).joined(separator: ",") + "}")]
            let rows: [Record]?
            if let connection {
                rows = try? await connection.extendedQuery(Self.typeNameSQL, parameters: parameters, limits: .metadata).records
            } else {
                rows = try? await records(Self.typeNameSQL, parameters, database: database, timeout: 10)
            }
            var found: [TypeNameKey: String] = [:]
            for row in rows ?? [] {
                if let oid = row.int("oid").flatMap({ UInt32(exactly: $0) }), let name = row.raw("typname") {
                    known[oid] = name
                    found[TypeNameKey(oid: oid, database: databaseName)] = name
                }
            }
            if !found.isEmpty {
                let additions = found
                typeNames.withLock { $0.merge(additions) { _, new in new } }
            }
        }
        var copy = result
        copy.results = result.results.map { set in
            set.with(columns: set.columns.map { column in
                var column = column
                if column.typeName == nil { column.typeName = known[column.typeOID] }
                return column
            })
        }
        return copy
    }

    static let typeNameSQL = "SELECT oid::text AS oid, typname FROM pg_type WHERE oid = ANY($1::oid[])"
}

/// Cache key for type names: OIDs below `FirstNormalObjectId` (16384) are fixed at initdb and the same in every
/// database; others are assigned per database.
struct TypeNameKey: Hashable, Sendable {
    let database: String
    let oid: UInt32

    init(oid: UInt32, database: String) {
        self.oid = oid
        self.database = oid < 16_384 ? "" : database
    }
}
