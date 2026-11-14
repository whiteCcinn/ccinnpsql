import CcinnPsqlKit
import PostgresKit
import SwiftUI

struct OperationsView: View {
    @Bindable var model: OperationsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.section {
                case .overview: OverviewPane(model: model)
                case .activity: ActivityPane(model: model)
                case .locks: LocksPane(model: model)
                case .replication: ReplicationPane(model: model)
                case .progress: ProgressPane(model: model)
                case .statements: StatementsPane(model: model)
                case .maintenance: MaintenancePane(model: model)
                case .settings: SettingsPane(model: model)
                case .roles: RolesPane(model: model)
                case .pooler: PoolerPane(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog(model.pendingAction?.title ?? "", isPresented: Binding(get: { model.pendingAction != nil }, set: { if !$0 { model.pendingAction = nil } }),
                            titleVisibility: .visible) {
            Button(model.pendingAction?.confirmLabel ?? "OK", role: .destructive) { model.runPendingAction() }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(model.availableSections) { section in
                let selected = model.section == section
                Button {
                    model.section = section
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let last = model.lastRefreshed {
                Text(last, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Auto", isOn: $model.autoRefresh).toggleStyle(.switch).controlSize(.mini).help("Refresh live sections every 4 seconds")
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.overview, retry: { model.refresh() }) { overview in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        StatTile(title: "Uptime", value: Format.duration(seconds: overview.uptimeSeconds), systemImage: "clock")
                        StatTile(title: "Connections", value: "\(overview.totalConnections) / \(overview.maxConnections.map(String.init) ?? "?")",
                                 systemImage: "person.2",
                                 tint: Double(overview.totalConnections) > Double(overview.maxConnections ?? Int.max) * 0.8 ? .orange : Theme.accent)
                        StatTile(title: "Oldest XID age", value: Format.count(overview.maxTransactionIDAge), systemImage: "hourglass.bottomhalf.filled",
                                 tint: (overview.maxTransactionIDAge ?? 0) > 1_000_000_000 ? .orange : Theme.accent)
                        StatTile(title: "Checkpoints (timed / requested)",
                                 value: "\(Format.count(overview.checkpointsTimed)) / \(Format.count(overview.checkpointsRequested))", systemImage: "flag.checkered")
                    }
                    Card(title: "Sessions by state", systemImage: "chart.pie") {
                        HStack(spacing: 14) {
                            ForEach(overview.connectionsByState.sorted { $0.value > $1.value }, id: \.key) { state, count in
                                HStack(spacing: 5) {
                                    Circle().fill(Theme.color(forState: state)).frame(width: 8, height: 8)
                                    Text(state).foregroundStyle(.secondary)
                                    Text("\(count)").monospacedDigit().fontWeight(.semibold)
                                }
                            }
                        }
                        .font(.callout)
                    }
                    Card(title: "Databases", systemImage: "cylinder.split.1x2") {
                        Table(overview.databases) {
                            TableColumn("Database") { Text($0.name).fontWeight(.medium) }
                            TableColumn("Size") { Text(Format.bytes($0.sizeBytes)).monospacedDigit() }.width(90)
                            TableColumn("Backends") { Text("\($0.backends)").monospacedDigit() }.width(70)
                            TableColumn("Cache hit") { Text($0.cacheHitRatio.map { Format.percent($0 * 100) } ?? "—").monospacedDigit() }.width(80)
                            TableColumn("Commits / rollbacks") { Text("\(Format.count($0.commits)) / \(Format.count($0.rollbacks))").monospacedDigit() }
                            TableColumn("Deadlocks") { Text(Format.count($0.deadlocks)).monospacedDigit() }.width(80)
                            TableColumn("Temp") { Text(Format.bytes($0.tempBytes)).monospacedDigit() }.width(80)
                            TableColumn("XID age") { database in
                                Text(Format.count(database.transactionIDAge)).monospacedDigit()
                                    .foregroundStyle((database.transactionIDAge ?? 0) > 1_000_000_000 ? .orange : .primary)
                            }.width(110)
                        }
                        .frame(minHeight: CGFloat(min(overview.databases.count, 12)) * 24 + 30)
                    }
                    Card(title: "Server", systemImage: "server.rack") {
                        let info = model.workspace.serverInfo
                        KeyValueList(items: [
                            ("Version", info.versionString), ("User", info.currentUser + (info.isSuperuser ? " (superuser)" : "")),
                            ("Role", info.isInRecovery ? "Standby (in recovery)" : "Primary"), ("TLS", info.tlsDescription ?? "Unencrypted"),
                            ("Pooler", info.pooler.displayName), ("Session state", info.poolingDetail),
                            ("Extensions", info.extensions.map { "\($0.name) \($0.version)" }.joined(separator: ", ")),
                        ])
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - Activity

private struct ActivityPane: View {
    @Bindable var model: OperationsModel
    @State private var selection: Int32?

    var body: some View {
        LoadableView(state: model.activity, retry: { model.refresh() }) { snapshot in
            let sessions = snapshot.sessions.filter { model.includeIdle || (!$0.isIdle && $0.state != nil) || !$0.blockedBy.isEmpty }
            let tree = BlockingTree.build(snapshot.sessions)
            VStack(spacing: 0) {
                HStack {
                    Text("\(sessions.count) sessions · \(snapshot.sessions.filter { $0.state == "active" }.count) active · \(snapshot.sessions.filter(\.isWaitingOnLock).count) waiting on locks")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("Show idle", isOn: $model.includeIdle).toggleStyle(.checkbox)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                if !tree.isEmpty {
                    BlockingTreeView(tree: tree, model: model)
                        .frame(maxHeight: 220)
                    Divider()
                }
                Table(sessions, selection: $selection) {
                    TableColumn("PID") { session in
                        HStack(spacing: 3) {
                            Text(String(session.pid)).monospacedDigit()
                            if session.isCurrentSession { Image(systemName: "person.crop.circle").foregroundStyle(.secondary).help("This connection") }
                        }
                    }.width(70)
                    TableColumn("User / DB") { Text([$0.user, $0.database].compactMap { $0 }.joined(separator: " @ ")).lineLimit(1) }
                    TableColumn("Application") { Text($0.applicationName ?? $0.backendType ?? "").lineLimit(1) }
                    TableColumn("State") { session in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(forState: session.state)).frame(width: 7, height: 7)
                            Text(session.state ?? session.backendType ?? "—").lineLimit(1)
                        }
                    }.width(130)
                    TableColumn("Wait") { session in
                        Text(session.waitDescription ?? "").foregroundStyle(Theme.color(forWait: session.waitEventType)).lineLimit(1)
                    }
                    TableColumn("Query time") { Text(Format.duration(seconds: $0.querySeconds)).monospacedDigit() }.width(80)
                    TableColumn("Xact time") { session in
                        Text(Format.duration(seconds: session.transactionSeconds)).monospacedDigit()
                            .foregroundStyle(session.isIdleInTransaction && (session.stateSeconds ?? 0) > 60 ? .orange : .primary)
                    }.width(80)
                    TableColumn("Blocked by") { Text($0.blockedBy.map(String.init).joined(separator: ", ")).foregroundStyle(.red) }.width(80)
                    TableColumn("Query") { Text(($0.query ?? "").replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(1) }
                }
                .contextMenu(forSelectionType: Int32.self) { pids in
                    if let pid = pids.first, let session = snapshot.sessions.first(where: { $0.pid == pid }) {
                        SessionActions(session: session, model: model)
                    }
                }
            }
        }
    }
}

private struct SessionActions: View {
    let session: ActivitySession
    let model: OperationsModel

    var body: some View {
        Button("Cancel Query…") { model.confirmSignal(session, terminate: false) }.disabled(session.isCurrentSession)
        Button("Terminate Session…", role: .destructive) { model.confirmSignal(session, terminate: true) }.disabled(session.isCurrentSession)
        Divider()
        if let query = session.query, !query.isEmpty {
            Button("Copy Query") { Pasteboard.copy(query) }
            Button("Open Query in Editor") { model.workspace.openSQL(text: query, database: session.database) }
        }
        Button("Copy PID") { Pasteboard.copy(String(session.pid)) }
    }
}

/// Blockers at the root, the sessions waiting on them beneath.
private struct BlockingTreeView: View {
    let tree: [BlockingNode]
    let model: OperationsModel

    private struct Row: Identifiable {
        let node: BlockingNode
        let depth: Int
        let id: String
    }

    private var rows: [Row] {
        var result: [Row] = []
        func visit(_ node: BlockingNode, depth: Int, path: String) {
            let id = path + "/\(node.session.pid)"
            result.append(Row(node: node, depth: depth, id: id))
            for waiter in node.waiters { visit(waiter, depth: depth + 1, path: id) }
        }
        for root in tree { visit(root, depth: 0, path: "") }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Blocking tree", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(rows) { row in
                        let session = row.node.session
                        HStack(spacing: 6) {
                            Color.clear.frame(width: CGFloat(row.depth) * 18)
                            Image(systemName: row.depth == 0 ? "lock.fill" : "hourglass").foregroundStyle(row.depth == 0 ? .red : .orange)
                            Text(String(session.pid)).monospacedDigit().fontWeight(.semibold)
                            Text([session.user, session.state].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(.secondary)
                            if row.depth == 0, row.node.blockedCount > 0 { Badge(text: "blocks \(row.node.blockedCount)", color: .red) }
                            if let wait = session.querySeconds { Text(Format.duration(seconds: wait)).monospacedDigit().foregroundStyle(.secondary) }
                            Text((session.query ?? "").replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(1)
                            Spacer()
                        }
                        .font(.callout)
                        .contextMenu { SessionActions(session: session, model: model) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
        .background(Color.red.opacity(0.04))
    }
}

// MARK: - Locks

private struct LocksPane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.locks, retry: { model.refresh() }) { locks in
            Table(locks) {
                TableColumn("PID") { Text($0.pid.map(String.init) ?? "—").monospacedDigit() }.width(60)
                TableColumn("Granted") { lock in
                    Image(systemName: lock.granted ? "checkmark.circle.fill" : "hourglass").foregroundStyle(lock.granted ? .green : .orange)
                }.width(60)
                TableColumn("Type") { Text($0.lockType) }.width(100)
                TableColumn("Mode") { Text($0.mode).font(Theme.monospacedSmall) }
                TableColumn("Relation") { Text($0.relation ?? $0.objectDetail ?? "") }
                TableColumn("Waiting") { Text($0.granted ? "" : Format.duration(seconds: $0.waitSeconds)).monospacedDigit() }.width(70)
                TableColumn("User") { Text($0.user ?? "") }.width(90)
                TableColumn("Query") { Text(($0.query ?? "").replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(1) }
            }
            .overlay { if locks.isEmpty { ContentUnavailableView("No Locks", systemImage: "lock.open") } }
        }
    }
}

// MARK: - Replication

private struct ReplicationPane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.replication, retry: { model.refresh() }) { replication in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        StatTile(title: "Role", value: replication.isInRecovery ? "Standby" : "Primary", systemImage: "server.rack")
                        StatTile(title: replication.isInRecovery ? "Replay LSN" : "Current WAL LSN", value: replication.currentLSN ?? "—", systemImage: "number")
                        StatTile(title: "Standbys", value: "\(replication.connections.count)", systemImage: "arrow.triangle.2.circlepath")
                        StatTile(title: "Slots", value: "\(replication.slots.count)", systemImage: "tray.2",
                                 tint: replication.slots.contains(where: \.isRisky) ? .orange : Theme.accent)
                    }
                    if let standby = replication.standby {
                        Card(title: "This server is a standby", systemImage: "arrow.down.circle") {
                            KeyValueList(items: [
                                ("Upstream", standby.upstream ?? "—"), ("WAL receiver", standby.receiverStatus ?? "not running"),
                                ("Received up to", standby.receiveLSN ?? "—"), ("Replayed up to", standby.replayLSN ?? "—"),
                                ("Replay delay", Format.duration(seconds: standby.replayDelaySeconds)), ("Replay paused", standby.isReplayPaused == true ? "Yes" : "No"),
                            ])
                        }
                    }
                    Card(title: "Standbys", systemImage: "arrow.triangle.2.circlepath") {
                        if replication.connections.isEmpty {
                            Text("No standby is streaming from this server.").foregroundStyle(.secondary)
                        } else {
                            Table(replication.connections) {
                                TableColumn("Application") { Text($0.applicationName ?? "—") }
                                TableColumn("Client") { Text($0.clientAddress ?? "local") }
                                TableColumn("State") { Text([$0.state, $0.syncState].compactMap { $0 }.joined(separator: " · ")) }
                                TableColumn("Replay lag") { connection in
                                    Text("\(Format.bytes(connection.replayLagBytes)) · \(Format.duration(seconds: connection.replayLagSeconds))").monospacedDigit()
                                }
                                TableColumn("Write / flush lag") { Text("\(Format.duration(seconds: $0.writeLagSeconds)) / \(Format.duration(seconds: $0.flushLagSeconds))") }
                            }
                            .frame(minHeight: CGFloat(min(replication.connections.count, 8)) * 24 + 30)
                        }
                    }
                    Card(title: "Replication slots", systemImage: "tray.2") {
                        if replication.slots.isEmpty {
                            Text("No replication slots.").foregroundStyle(.secondary)
                        } else {
                            ForEach(replication.slots) { slot in
                                HStack(spacing: 8) {
                                    Image(systemName: slot.isActive ? "circle.fill" : "circle").foregroundStyle(slot.isActive ? .green : .orange)
                                    Text(slot.name).fontWeight(.medium)
                                    Badge(text: slot.slotType, color: .secondary)
                                    if let plugin = slot.plugin { Text(plugin).foregroundStyle(.secondary) }
                                    if let status = slot.walStatus { Badge(text: status, color: slot.isRisky ? .orange : .green) }
                                    if slot.isTemporary { Badge(text: "temporary", color: .secondary) }
                                    Spacer()
                                    Text("retains \(Format.bytes(slot.retainedBytes))").monospacedDigit()
                                        .foregroundStyle(slot.isRisky && (slot.retainedBytes ?? 0) > 1 << 30 ? .orange : .secondary)
                                }
                                .help(slot.isActive ? "Active (pid \(slot.activePID.map(String.init) ?? "?"))"
                                      : "Inactive: the slot keeps WAL on disk until a consumer reconnects or the slot is dropped")
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - Progress

private struct ProgressPane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.progress, retry: { model.refresh() }) { entries in
            List(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Badge(text: entry.command, color: Theme.accent)
                        Text(entry.relation ?? entry.database ?? "").fontWeight(.medium)
                        Text("pid \(entry.pid)").foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.phase ?? "").foregroundStyle(.secondary)
                    }
                    if let fraction = entry.fraction {
                        ProgressView(value: fraction) { Text(Format.percent(fraction * 100)).font(.caption) }
                    }
                    Text(entry.details.map { "\($0.name.replacingOccurrences(of: "_", with: " ")): \($0.value)" }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Nothing Running", systemImage: "hourglass",
                                           description: Text("VACUUM, ANALYZE, CREATE INDEX, CLUSTER, COPY and base backups show their progress here."))
                }
            }
        }
    }
}

// MARK: - Statements

private struct StatementsPane: View {
    let model: OperationsModel
    @State private var sortOrder = [KeyPathComparator(\StatementStatistics.totalMilliseconds, order: .reverse)]

    var body: some View {
        LoadableView(state: model.statements, retry: { model.refresh() }) { availability, statements in
            switch availability {
            case .available:
                Table(statements.sorted(using: sortOrder), sortOrder: $sortOrder) {
                    TableColumn("Query") { Text($0.query.replacingOccurrences(of: "\n", with: " ")).font(Theme.monospacedSmall).lineLimit(2) }
                    TableColumn("Calls", value: \.calls) { Text(Format.count($0.calls)).monospacedDigit() }.width(80)
                    TableColumn("Total", value: \.totalMilliseconds) { Text(Format.duration(milliseconds: $0.totalMilliseconds)).monospacedDigit() }.width(90)
                    TableColumn("Mean") { Text($0.meanMilliseconds.map { Format.duration(milliseconds: $0) } ?? "—").monospacedDigit() }.width(80)
                    TableColumn("Rows") { Text(Format.count($0.rows)).monospacedDigit() }.width(80)
                    TableColumn("Cache hit") { Text($0.cacheHitRatio.map { Format.percent($0 * 100) } ?? "—").monospacedDigit() }.width(80)
                    TableColumn("User") { Text($0.user ?? "") }.width(90)
                }
                .contextMenu(forSelectionType: StatementStatistics.ID.self) { ids in
                    if let id = ids.first, let statement = statements.first(where: { $0.id == id }) {
                        Button("Copy Query") { Pasteboard.copy(statement.query) }
                        Button("Open in Editor") { model.workspace.openSQL(text: statement.query) }
                    }
                }
            case .extensionMissing:
                ContentUnavailableView {
                    Label("pg_stat_statements Is Not Installed", systemImage: "list.number")
                } description: {
                    Text("Add pg_stat_statements to shared_preload_libraries, restart PostgreSQL, then run CREATE EXTENSION pg_stat_statements; in \(model.workspace.currentDatabase).")
                }
            case let .notPreloaded(message), let .failed(message):
                ContentUnavailableView("pg_stat_statements Is Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
    }
}

// MARK: - Maintenance

private struct MaintenancePane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.maintenance, retry: { model.refresh() }) { candidates, unused in
            VSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    Label("Vacuum and freeze candidates in \(model.workspace.currentDatabase)", systemImage: "trash").font(.callout.weight(.semibold)).padding(10)
                    Table(candidates) {
                        TableColumn("Table") { Text("\($0.schema).\($0.name)") }
                        TableColumn("Dead tuples") { candidate in
                            Text("\(Format.count(candidate.deadTuples)) (\(candidate.deadRatio.map { Format.percent($0 * 100) } ?? "—"))").monospacedDigit()
                                .foregroundStyle((candidate.deadRatio ?? 0) > 0.2 ? .orange : .primary)
                        }
                        TableColumn("Last vacuum") { Text($0.lastVacuum.map { $0.formatted(.relative(presentation: .named)) } ?? "never") }
                        TableColumn("Last analyze") { Text($0.lastAnalyze.map { $0.formatted(.relative(presentation: .named)) } ?? "never") }
                        TableColumn("XID age") { Text(Format.count($0.transactionIDAge)).monospacedDigit() }.width(100)
                        TableColumn("Size") { Text(Format.bytes($0.totalBytes)).monospacedDigit() }.width(90)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Label("Unused indexes (no scans since statistics reset)", systemImage: "zzz").font(.callout.weight(.semibold)).padding(10)
                    Table(unused) {
                        TableColumn("Index") { Text($0.index).fontWeight(.medium) }
                        TableColumn("Table") { Text("\($0.schema).\($0.table)") }
                        TableColumn("Size") { Text(Format.bytes($0.sizeBytes)).monospacedDigit() }.width(90)
                    }
                    .overlay { if unused.isEmpty { ContentUnavailableView("No Unused Indexes", systemImage: "checkmark.circle") } }
                }
            }
        }
    }
}

// MARK: - Settings and roles

private struct SettingsPane: View {
    let model: OperationsModel
    @State private var search = ""
    @State private var onlyChanged = false

    var body: some View {
        LoadableView(state: model.settings, retry: { model.refresh() }) { settings in
            let filtered = settings.filter { setting in
                (!onlyChanged || setting.isNonDefault || setting.pendingRestart)
                    && (search.isEmpty || setting.name.localizedCaseInsensitiveContains(search) || (setting.description ?? "").localizedCaseInsensitiveContains(search))
            }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter settings", text: $search).textFieldStyle(.plain)
                    Toggle("Changed only", isOn: $onlyChanged).toggleStyle(.checkbox)
                    Text("\(filtered.count) of \(settings.count)").foregroundStyle(.secondary)
                }
                .padding(10)
                Table(filtered) {
                    TableColumn("Name") { setting in
                        HStack(spacing: 4) {
                            Text(setting.name).fontWeight(setting.isNonDefault ? .semibold : .regular)
                            if setting.pendingRestart { Badge(text: "restart", color: .orange) }
                        }
                    }
                    TableColumn("Value") { Text($0.displayValue).font(Theme.monospacedSmall).lineLimit(1) }
                    TableColumn("Source") { Text($0.source ?? "") }.width(110)
                    TableColumn("Context") { Text($0.context ?? "") }.width(90)
                    TableColumn("Description") { Text($0.description ?? "").foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }
}

private struct RolesPane: View {
    let model: OperationsModel

    var body: some View {
        LoadableView(state: model.roles, retry: { model.refresh() }) { roles in
            Table(roles) {
                TableColumn("Role") { role in
                    HStack(spacing: 4) {
                        Image(systemName: role.canLogin ? "person.fill" : "person.2").foregroundStyle(role.isSuperuser ? .red : .secondary)
                        Text(role.name).fontWeight(.medium)
                    }
                }
                TableColumn("Attributes") { Text($0.attributes.joined(separator: ", ")).foregroundStyle(.secondary) }
                TableColumn("Member of") { Text($0.memberOf.joined(separator: ", ")) }
                TableColumn("Connections") { Text($0.connectionLimit.map { $0 < 0 ? "unlimited" : String($0) } ?? "—") }.width(90)
                TableColumn("Valid until") { Text($0.validUntil ?? "") }.width(140)
            }
        }
    }
}

private struct PoolerPane: View {
    @Bindable var model: OperationsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Report", selection: $model.poolerCommand) {
                    ForEach(model.poolerCommands, id: \.self) { Text("SHOW \($0)").tag($0) }
                }
                .fixedSize()
                Spacer()
                Text(model.workspace.serverInfo.pooler.displayName).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            LoadableView(state: model.poolerReport, retry: { model.refresh() }) { result in
                ResultGrid(resultID: model.poolerReportID, columns: result.columns, rows: result.rows, insertTableName: "pooler", onInspect: { _ in })
            }
        }
    }
}
