import Foundation

/// One row of `pg_stat_activity`.
public struct ActivitySession: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let user: String?
    public let database: String?
    public let applicationName: String?
    public let clientAddress: String?
    public let backendType: String?
    public let state: String?
    public let waitEventType: String?
    public let waitEvent: String?
    public let query: String?
    public let queryID: String?
    /// Seconds since the current query started (computed on the server, no clock skew).
    public let querySeconds: Double?
    public let transactionSeconds: Double?
    public let backendSeconds: Double?
    public let stateSeconds: Double?
    public let blockedBy: [Int32]
    public let leaderPID: Int32?
    public let backendXID: String?
    public let backendXmin: String?
    /// The app's own connection that produced the snapshot.
    public let isCurrentSession: Bool

    public init(pid: Int32, user: String? = nil, database: String? = nil, applicationName: String? = nil, clientAddress: String? = nil,
                backendType: String? = nil, state: String? = nil, waitEventType: String? = nil, waitEvent: String? = nil, query: String? = nil,
                queryID: String? = nil, querySeconds: Double? = nil, transactionSeconds: Double? = nil, backendSeconds: Double? = nil,
                stateSeconds: Double? = nil, blockedBy: [Int32] = [], leaderPID: Int32? = nil, backendXID: String? = nil,
                backendXmin: String? = nil, isCurrentSession: Bool = false) {
        self.pid = pid
        self.user = user
        self.database = database
        self.applicationName = applicationName
        self.clientAddress = clientAddress
        self.backendType = backendType
        self.state = state
        self.waitEventType = waitEventType
        self.waitEvent = waitEvent
        self.query = query
        self.queryID = queryID
        self.querySeconds = querySeconds
        self.transactionSeconds = transactionSeconds
        self.backendSeconds = backendSeconds
        self.stateSeconds = stateSeconds
        self.blockedBy = blockedBy
        self.leaderPID = leaderPID
        self.backendXID = backendXID
        self.backendXmin = backendXmin
        self.isCurrentSession = isCurrentSession
    }

    /// Client backends (not autovacuum, WAL sender, checkpointer, …).
    public var isClientBackend: Bool { backendType == nil ? user != nil : backendType == "client backend" }
    public var isIdle: Bool { state == "idle" }
    public var isIdleInTransaction: Bool { state?.hasPrefix("idle in transaction") == true }
    public var isWaitingOnLock: Bool { waitEventType == "Lock" }
    public var waitDescription: String? {
        guard let waitEventType else { return nil }
        return waitEvent.map { "\(waitEventType): \($0)" } ?? waitEventType
    }
}

/// A snapshot of activity taken on one node.
public struct ActivitySnapshot: Sendable {
    public let sessions: [ActivitySession]
    /// The node the snapshot was taken on (cancel/terminate must land there).
    public let node: NodeFingerprint?
    public let takenAt: Date

    public init(sessions: [ActivitySession], node: NodeFingerprint?, takenAt: Date = Date()) {
        self.sessions = sessions
        self.node = node
        self.takenAt = takenAt
    }
}

/// A node of the lock-wait forest: a session and the sessions waiting on it.
public struct BlockingNode: Sendable, Hashable, Identifiable {
    public var id: Int32 { session.pid }
    public let session: ActivitySession
    public let waiters: [BlockingNode]

    public init(session: ActivitySession, waiters: [BlockingNode]) {
        self.session = session
        self.waiters = waiters
    }

    /// Number of sessions blocked (directly or indirectly) by this one.
    public var blockedCount: Int { waiters.reduce(0) { $0 + 1 + $1.blockedCount } }
}

/// Builds the blocking tree from `pg_blocking_pids` (design D11).
public enum BlockingTree {
    /// Roots are sessions that block others but are not blocked themselves (or are part of a cycle such as a
    /// deadlock being resolved). Every blocked session appears under each of its blockers; recursion is cycle-safe
    /// and depth-bounded.
    public static func build(_ sessions: [ActivitySession], maxDepth: Int = 16) -> [BlockingNode] {
        let byPID = Dictionary(sessions.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var waitersOf: [Int32: [Int32]] = [:]
        for session in sessions {
            for blocker in Set(session.blockedBy) where blocker != session.pid && byPID[blocker] != nil {
                waitersOf[blocker, default: []].append(session.pid)
            }
        }
        guard !waitersOf.isEmpty else { return [] }
        func node(_ pid: Int32, path: Set<Int32>, depth: Int) -> BlockingNode? {
            guard let session = byPID[pid] else { return nil }
            guard depth < maxDepth else { return BlockingNode(session: session, waiters: []) }
            let next = (waitersOf[pid] ?? []).filter { !path.contains($0) }.sorted()
            return BlockingNode(session: session, waiters: next.compactMap { node($0, path: path.union([$0]), depth: depth + 1) })
        }
        var roots = waitersOf.keys.filter { pid in
            guard let session = byPID[pid] else { return false }
            return session.blockedBy.allSatisfy { byPID[$0] == nil || $0 == pid }
        }
        if roots.isEmpty {
            // Pure cycle (deadlock being detected): start from the oldest blocked transaction.
            roots = [waitersOf.keys.min { (byPID[$0]?.transactionSeconds ?? 0) > (byPID[$1]?.transactionSeconds ?? 0) } ?? 0]
        }
        return roots.sorted().compactMap { node($0, path: [$0], depth: 0) }
            .sorted { $0.blockedCount > $1.blockedCount }
    }
}

/// A row of `pg_locks` with its session.
public struct LockInfo: Sendable, Hashable, Identifiable {
    public var id: String { "\(pid ?? -1)-\(lockType)-\(relation ?? "")-\(mode)-\(granted)-\(objectDetail ?? "")" }
    public let pid: Int32?
    public let lockType: String
    public let relation: String?
    public let mode: String
    public let granted: Bool
    public let objectDetail: String?
    public let user: String?
    public let query: String?
    public let state: String?
    public let waitSeconds: Double?

    public init(pid: Int32?, lockType: String, relation: String?, mode: String, granted: Bool, objectDetail: String? = nil,
                user: String? = nil, query: String? = nil, state: String? = nil, waitSeconds: Double? = nil) {
        self.pid = pid
        self.lockType = lockType
        self.relation = relation
        self.mode = mode
        self.granted = granted
        self.objectDetail = objectDetail
        self.user = user
        self.query = query
        self.state = state
        self.waitSeconds = waitSeconds
    }
}

/// A standby connected to this server (`pg_stat_replication`).
public struct ReplicationConnection: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let user: String?
    public let applicationName: String?
    public let clientAddress: String?
    public let state: String?
    public let syncState: String?
    public let sentLSN: String?
    public let writeLSN: String?
    public let flushLSN: String?
    public let replayLSN: String?
    public let replayLagBytes: Int64?
    public let writeLagSeconds: Double?
    public let flushLagSeconds: Double?
    public let replayLagSeconds: Double?

    public init(pid: Int32, user: String?, applicationName: String?, clientAddress: String?, state: String?, syncState: String?,
                sentLSN: String?, writeLSN: String?, flushLSN: String?, replayLSN: String?, replayLagBytes: Int64?, writeLagSeconds: Double?,
                flushLagSeconds: Double?, replayLagSeconds: Double?) {
        self.pid = pid
        self.user = user
        self.applicationName = applicationName
        self.clientAddress = clientAddress
        self.state = state
        self.syncState = syncState
        self.sentLSN = sentLSN
        self.writeLSN = writeLSN
        self.flushLSN = flushLSN
        self.replayLSN = replayLSN
        self.replayLagBytes = replayLagBytes
        self.writeLagSeconds = writeLagSeconds
        self.flushLagSeconds = flushLagSeconds
        self.replayLagSeconds = replayLagSeconds
    }
}

public struct ReplicationSlot: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let plugin: String?
    public let slotType: String
    public let database: String?
    public let isActive: Bool
    public let activePID: Int32?
    public let isTemporary: Bool
    public let restartLSN: String?
    public let confirmedFlushLSN: String?
    /// WAL kept on disk because of this slot.
    public let retainedBytes: Int64?
    /// `reserved`, `extended`, `unreserved`, `lost` (PostgreSQL 13+).
    public let walStatus: String?
    public let safeWALBytes: Int64?

    public init(name: String, plugin: String?, slotType: String, database: String?, isActive: Bool, activePID: Int32?, isTemporary: Bool,
                restartLSN: String?, confirmedFlushLSN: String?, retainedBytes: Int64?, walStatus: String?, safeWALBytes: Int64?) {
        self.name = name
        self.plugin = plugin
        self.slotType = slotType
        self.database = database
        self.isActive = isActive
        self.activePID = activePID
        self.isTemporary = isTemporary
        self.restartLSN = restartLSN
        self.confirmedFlushLSN = confirmedFlushLSN
        self.retainedBytes = retainedBytes
        self.walStatus = walStatus
        self.safeWALBytes = safeWALBytes
    }

    /// Inactive slots retain WAL indefinitely and can fill the disk.
    public var isRisky: Bool { !isActive || walStatus == "lost" || walStatus == "unreserved" }
}

/// Recovery facts when the server is a standby.
public struct StandbyStatus: Sendable, Hashable {
    public let receiveLSN: String?
    public let replayLSN: String?
    public let replayDelaySeconds: Double?
    public let isReplayPaused: Bool?
    public let upstream: String?
    public let receiverStatus: String?

    public init(receiveLSN: String?, replayLSN: String?, replayDelaySeconds: Double?, isReplayPaused: Bool?, upstream: String?, receiverStatus: String?) {
        self.receiveLSN = receiveLSN
        self.replayLSN = replayLSN
        self.replayDelaySeconds = replayDelaySeconds
        self.isReplayPaused = isReplayPaused
        self.upstream = upstream
        self.receiverStatus = receiverStatus
    }
}

public struct ReplicationOverview: Sendable {
    public let isInRecovery: Bool
    public let currentLSN: String?
    public let connections: [ReplicationConnection]
    public let slots: [ReplicationSlot]
    public let standby: StandbyStatus?

    public init(isInRecovery: Bool, currentLSN: String?, connections: [ReplicationConnection], slots: [ReplicationSlot], standby: StandbyStatus?) {
        self.isInRecovery = isInRecovery
        self.currentLSN = currentLSN
        self.connections = connections
        self.slots = slots
        self.standby = standby
    }
}

/// A running maintenance command from `pg_stat_progress_*`.
public struct ProgressEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(command)-\(pid)" }
    public let command: String
    public let pid: Int32
    public let database: String?
    public let relation: String?
    public let phase: String?
    /// Completion between 0 and 1 when the view reports enough to compute it.
    public let fraction: Double?
    public let details: [ProgressDetail]
    public let query: String?

    public init(command: String, pid: Int32, database: String?, relation: String?, phase: String?, fraction: Double?, details: [ProgressDetail], query: String?) {
        self.command = command
        self.pid = pid
        self.database = database
        self.relation = relation
        self.phase = phase
        self.fraction = fraction
        self.details = details
        self.query = query
    }
}

public struct ProgressDetail: Sendable, Hashable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A row of `pg_stat_statements`.
public struct StatementStatistics: Sendable, Hashable, Identifiable {
    public var id: String { "\(queryID ?? "")-\(user ?? "")-\(database ?? "")-\(query.prefix(64))" }
    public let queryID: String?
    public let query: String
    public let user: String?
    public let database: String?
    public let calls: Int64
    public let totalMilliseconds: Double
    public let meanMilliseconds: Double?
    public let maxMilliseconds: Double?
    public let rows: Int64?
    public let sharedBlocksHit: Int64?
    public let sharedBlocksRead: Int64?
    public let tempBlocksWritten: Int64?

    public init(queryID: String?, query: String, user: String?, database: String?, calls: Int64, totalMilliseconds: Double, meanMilliseconds: Double?,
                maxMilliseconds: Double?, rows: Int64?, sharedBlocksHit: Int64?, sharedBlocksRead: Int64?, tempBlocksWritten: Int64?) {
        self.queryID = queryID
        self.query = query
        self.user = user
        self.database = database
        self.calls = calls
        self.totalMilliseconds = totalMilliseconds
        self.meanMilliseconds = meanMilliseconds
        self.maxMilliseconds = maxMilliseconds
        self.rows = rows
        self.sharedBlocksHit = sharedBlocksHit
        self.sharedBlocksRead = sharedBlocksRead
        self.tempBlocksWritten = tempBlocksWritten
    }

    public var cacheHitRatio: Double? {
        guard let hit = sharedBlocksHit, let read = sharedBlocksRead, hit &+ read > 0 else { return nil }
        return Double(hit) / Double(hit &+ read)
    }
}

/// Why top statements are unavailable.
public enum StatementStatisticsAvailability: Sendable, Equatable {
    case available
    case extensionMissing
    case notPreloaded(String)
    case failed(String)
}

public struct ServerSetting: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let setting: String?
    public let unit: String?
    public let category: String?
    public let description: String?
    public let source: String?
    public let bootValue: String?
    public let resetValue: String?
    public let context: String?
    public let pendingRestart: Bool

    public init(name: String, setting: String?, unit: String?, category: String?, description: String?, source: String?, bootValue: String?,
                resetValue: String?, context: String?, pendingRestart: Bool) {
        self.name = name
        self.setting = setting
        self.unit = unit
        self.category = category
        self.description = description
        self.source = source
        self.bootValue = bootValue
        self.resetValue = resetValue
        self.context = context
        self.pendingRestart = pendingRestart
    }

    /// Set somewhere other than the built-in default.
    public var isNonDefault: Bool { source != nil && source != "default" && source != "override" }

    /// Setting with its unit expanded (`128MB` for `16384 × 8kB`).
    public var displayValue: String {
        guard let setting else { return "" }
        guard let unit, let number = Double(setting), number >= 0 else { return unit.map { "\(setting) \($0)" } ?? setting }
        let multipliers: [String: Double] = ["B": 1, "kB": 1_024, "MB": 1_048_576, "8kB": 8_192, "16kB": 16_384, "32kB": 32_768, "64kB": 65_536, "16MB": 16_777_216]
        if let multiplier = multipliers[unit] {
            let bytes = (number * multiplier).rounded()
            guard bytes.isFinite, bytes < 9e18 else { return "\(setting) \(unit)" }
            return ByteFormat.string(Int64(bytes))
        }
        return "\(setting) \(unit)"
    }
}

public struct RoleInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let isSuperuser: Bool
    public let canLogin: Bool
    public let canCreateRole: Bool
    public let canCreateDatabase: Bool
    public let isReplication: Bool
    public let bypassesRLS: Bool
    public let inherits: Bool
    public let connectionLimit: Int?
    public let validUntil: String?
    public let memberOf: [String]
    public let comment: String?

    public init(name: String, isSuperuser: Bool, canLogin: Bool, canCreateRole: Bool, canCreateDatabase: Bool, isReplication: Bool,
                bypassesRLS: Bool, inherits: Bool, connectionLimit: Int?, validUntil: String?, memberOf: [String], comment: String?) {
        self.name = name
        self.isSuperuser = isSuperuser
        self.canLogin = canLogin
        self.canCreateRole = canCreateRole
        self.canCreateDatabase = canCreateDatabase
        self.isReplication = isReplication
        self.bypassesRLS = bypassesRLS
        self.inherits = inherits
        self.connectionLimit = connectionLimit
        self.validUntil = validUntil
        self.memberOf = memberOf
        self.comment = comment
    }

    public var attributes: [String] {
        var list: [String] = []
        if isSuperuser { list.append("Superuser") }
        if canLogin { list.append("Login") }
        if canCreateRole { list.append("Create role") }
        if canCreateDatabase { list.append("Create DB") }
        if isReplication { list.append("Replication") }
        if bypassesRLS { list.append("Bypass RLS") }
        if !inherits { list.append("No inherit") }
        return list
    }
}

/// Per-database activity counters (`pg_stat_database`).
public struct DatabaseStatistics: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let backends: Int
    public let commits: Int64?
    public let rollbacks: Int64?
    public let blocksRead: Int64?
    public let blocksHit: Int64?
    public let deadlocks: Int64?
    public let tempBytes: Int64?
    public let conflicts: Int64?
    public let sizeBytes: Int64?
    public let transactionIDAge: Int64?

    public init(name: String, backends: Int, commits: Int64?, rollbacks: Int64?, blocksRead: Int64?, blocksHit: Int64?, deadlocks: Int64?,
                tempBytes: Int64?, conflicts: Int64?, sizeBytes: Int64?, transactionIDAge: Int64?) {
        self.name = name
        self.backends = backends
        self.commits = commits
        self.rollbacks = rollbacks
        self.blocksRead = blocksRead
        self.blocksHit = blocksHit
        self.deadlocks = deadlocks
        self.tempBytes = tempBytes
        self.conflicts = conflicts
        self.sizeBytes = sizeBytes
        self.transactionIDAge = transactionIDAge
    }

    public var cacheHitRatio: Double? {
        guard let hit = blocksHit, let read = blocksRead, hit &+ read > 0 else { return nil }
        return Double(hit) / Double(hit &+ read)
    }
}

public struct ServerOverview: Sendable {
    public let uptimeSeconds: Double?
    public let connectionsByState: [String: Int]
    public let maxConnections: Int?
    public let databases: [DatabaseStatistics]
    /// Oldest transaction-ID age of any database (wraparound risk above ~1.5 billion).
    public let maxTransactionIDAge: Int64?
    public let checkpointsTimed: Int64?
    public let checkpointsRequested: Int64?

    public init(uptimeSeconds: Double?, connectionsByState: [String: Int], maxConnections: Int?, databases: [DatabaseStatistics],
                maxTransactionIDAge: Int64?, checkpointsTimed: Int64?, checkpointsRequested: Int64?) {
        self.uptimeSeconds = uptimeSeconds
        self.connectionsByState = connectionsByState
        self.maxConnections = maxConnections
        self.databases = databases
        self.maxTransactionIDAge = maxTransactionIDAge
        self.checkpointsTimed = checkpointsTimed
        self.checkpointsRequested = checkpointsRequested
    }

    public var totalConnections: Int { connectionsByState.values.reduce(0, +) }
}

/// A table that needs maintenance attention (dead tuples, stale vacuum, transaction-ID age).
public struct MaintenanceCandidate: Sendable, Hashable, Identifiable {
    public var id: String { "\(schema).\(name)" }
    public let schema: String
    public let name: String
    public let liveTuples: Int64?
    public let deadTuples: Int64?
    public let lastVacuum: Date?
    public let lastAnalyze: Date?
    public let transactionIDAge: Int64?
    public let totalBytes: Int64?

    public init(schema: String, name: String, liveTuples: Int64?, deadTuples: Int64?, lastVacuum: Date?, lastAnalyze: Date?,
                transactionIDAge: Int64?, totalBytes: Int64?) {
        self.schema = schema
        self.name = name
        self.liveTuples = liveTuples
        self.deadTuples = deadTuples
        self.lastVacuum = lastVacuum
        self.lastAnalyze = lastAnalyze
        self.transactionIDAge = transactionIDAge
        self.totalBytes = totalBytes
    }

    public var deadRatio: Double? {
        guard let live = liveTuples, let dead = deadTuples, live &+ dead > 0 else { return nil }
        return Double(dead) / Double(live &+ dead)
    }
}

/// An index across the database with usage, for the unused-index report.
public struct IndexUsage: Sendable, Hashable, Identifiable {
    public var id: String { "\(schema).\(index)" }
    public let schema: String
    public let table: String
    public let index: String
    public let scans: Int64
    public let sizeBytes: Int64?
    public let isUnique: Bool

    public init(schema: String, table: String, index: String, scans: Int64, sizeBytes: Int64?, isUnique: Bool) {
        self.schema = schema
        self.table = table
        self.index = index
        self.scans = scans
        self.sizeBytes = sizeBytes
        self.isUnique = isUnique
    }
}

/// Human-readable byte counts (binary units, as PostgreSQL's `pg_size_pretty`).
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        let units = ["bytes", "kB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        if unit == 0 { return "\(bytes) bytes" }
        return value >= 100 ? "\(Int(value.rounded())) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }
}
