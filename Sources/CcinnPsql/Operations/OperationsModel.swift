import CcinnPsqlKit
import Foundation
import Observation
import PostgresKit

/// Server operations: overview, activity with the blocking tree, locks, replication, progress, top statements,
/// maintenance, settings, roles and pooler reports. Refreshes the visible section periodically while auto-refresh is on.
@MainActor
@Observable
final class OperationsModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case locks = "Locks"
        case replication = "Replication"
        case progress = "Progress"
        case statements = "Statements"
        case maintenance = "Maintenance"
        case settings = "Settings"
        case roles = "Roles"
        case pooler = "Pooler"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .activity: "bolt.horizontal.circle"
            case .locks: "lock"
            case .replication: "arrow.triangle.2.circlepath"
            case .progress: "hourglass"
            case .statements: "list.number"
            case .maintenance: "wrench.and.screwdriver"
            case .settings: "slider.horizontal.3"
            case .roles: "person.2"
            case .pooler: "arrow.triangle.branch"
            }
        }

        /// Sections that change quickly enough to auto-refresh.
        var isLive: Bool { [.overview, .activity, .locks, .replication, .progress].contains(self) }
    }

    unowned let workspace: WorkspaceModel
    var section: Section { didSet { if section != oldValue { refresh() } } }
    var autoRefresh = true { didSet { autoRefresh ? startAutoRefresh() : stopAutoRefresh() } }
    var lastRefreshed: Date?
    var includeIdle = false
    var poolerCommand = "POOLS" { didSet { if poolerCommand != oldValue { refresh() } } }

    var overview: Loadable<ServerOverview> = .idle
    var activity: Loadable<ActivitySnapshot> = .idle
    var locks: Loadable<[LockInfo]> = .idle
    var replication: Loadable<ReplicationOverview> = .idle
    var progress: Loadable<[ProgressEntry]> = .idle
    var statements: Loadable<(StatementStatisticsAvailability, [StatementStatistics])> = .idle
    var maintenance: Loadable<([MaintenanceCandidate], [IndexUsage])> = .idle
    var settings: Loadable<[ServerSetting]> = .idle
    var roles: Loadable<[RoleInfo]> = .idle
    var poolerReport: Loadable<ResultSet> = .idle
    private(set) var poolerReportID = UUID()
    var pendingAction: PendingAction?

    struct PendingAction: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let run: @MainActor () async throws -> Void
    }

    private var refreshTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var isRefreshing = false

    init(workspace: WorkspaceModel, section: Section) {
        self.workspace = workspace
        self.section = workspace.isConsole ? .pooler : section
        refresh()
        startAutoRefresh()
    }

    var client: PostgresClient { workspace.client }

    var availableSections: [Section] {
        if workspace.isConsole { return [.pooler] }
        var sections = Section.allCases.filter { $0 != .pooler }
        // Pooler reports need Pgpool (SHOW POOL_*) or PgBouncer's admin console (handled above).
        if case .pgpool = workspace.serverInfo.pooler { sections.append(.pooler) }
        return sections
    }

    var poolerCommands: [String] {
        if case .pgpool = workspace.serverInfo.pooler { return ["POOL_NODES", "POOL_PROCESSES", "POOL_POOLS", "POOL_HEALTH_CHECK_STATS"] }
        return ["POOLS", "STATS", "CLIENTS", "SERVERS", "DATABASES", "CONFIG", "LISTS"]
    }

    // MARK: Refresh

    /// Timer refreshes are skipped while one is still running (a slow server is never interrupted half-way).
    func refresh(fromTimer: Bool = false) {
        if fromTimer, isRefreshing { return }
        if fromTimer, !section.isLive { return }
        refreshTask?.cancel()
        let section = section
        let database = workspace.currentDatabase
        isRefreshing = true
        refreshTask = Task {
            defer { if !Task.isCancelled { isRefreshing = false } }
            let client = client
            switch section {
            case .overview:
                await load({ self.overview = $0 }, keep: overview.value) { try await client.overview() }
            case .activity:
                await load({ self.activity = $0 }, keep: activity.value) { try await client.activity() }
            case .locks:
                await load({ self.locks = $0 }, keep: locks.value) { try await client.locks() }
            case .replication:
                await load({ self.replication = $0 }, keep: replication.value) { try await client.replication() }
            case .progress:
                await load({ self.progress = $0 }, keep: progress.value) { try await client.progress() }
            case .statements:
                await load({ self.statements = $0 }, keep: statements.value) { try await client.topStatements(limit: 200, database: database) }
            case .maintenance:
                await load({ self.maintenance = $0 }, keep: maintenance.value) {
                    async let candidates = client.maintenanceCandidates(limit: 100, database: database)
                    async let unused = client.unusedIndexes(limit: 200, database: database)
                    return (try await candidates, try await unused)
                }
            case .settings:
                await load({ self.settings = $0 }, keep: settings.value) { try await client.settings() }
            case .roles:
                await load({ self.roles = $0 }, keep: roles.value) { try await client.roles() }
            case .pooler:
                let command = poolerCommand
                poolerReportID = UUID()
                await load({ self.poolerReport = $0 }, keep: nil) {
                    guard let result = try await client.poolerReport(command).lastRowSet else {
                        throw PostgresError(.protocolViolation, "The pooler returned no rows")
                    }
                    return result
                }
            }
            if !Task.isCancelled { lastRefreshed = Date() }
        }
    }

    /// Shows a spinner only on the first load; later refreshes swap data in place.
    private func load<Value>(_ assign: (Loadable<Value>) -> Void, keep current: Value?, _ body: () async throws -> Value) async {
        if current == nil { assign(.loading) }
        do {
            let value = try await body()
            guard !Task.isCancelled else { return }
            assign(.loaded(value))
        } catch {
            guard !Task.isCancelled else { return }
            assign(.failed(describe(error)))
        }
    }

    func startAutoRefresh() {
        guard autoRefresh, loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self, !Task.isCancelled, self.autoRefresh else { return }
                self.refresh(fromTimer: true)
            }
        }
    }

    func stopAutoRefresh() {
        loopTask?.cancel()
        loopTask = nil
    }

    func close() {
        stopAutoRefresh()
        refreshTask?.cancel()
    }

    // MARK: Actions

    /// Cancel or terminate a backend, guarded by the node the snapshot was taken on.
    func confirmSignal(_ session: ActivitySession, terminate: Bool) {
        let node = activity.value?.node
        let pid = session.pid
        pendingAction = PendingAction(
            title: terminate ? "Terminate backend \(pid)?" : "Cancel the query of backend \(pid)?",
            message: [session.user.map { "\($0) @ \(session.database ?? "")" }, session.query.map { String($0.prefix(300)) }]
                .compactMap { $0 }.joined(separator: "\n\n"),
            confirmLabel: terminate ? "Terminate" : "Cancel Query") { [client] in
                let signalled = terminate
                    ? try await client.terminateBackend(pid, observedOn: node)
                    : try await client.cancelBackend(pid, observedOn: node)
                if !signalled { throw PostgresError(.server, "Backend \(pid) is gone or could not be signalled") }
            }
    }

    func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        Task {
            do {
                try await action.run()
                workspace.showToast("Done")
            } catch {
                workspace.showToast(describe(error), isError: true)
            }
            try? await Task.sleep(for: .milliseconds(400))
            refresh()
        }
    }
}
