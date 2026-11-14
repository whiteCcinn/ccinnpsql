import CcinnPsqlKit
import PostgresKit
import SwiftUI

struct ObjectDetailView: View {
    @Bindable var model: ObjectDetailModel

    var body: some View {
        VStack(spacing: 0) {
            ObjectHeader(model: model)
            SectionBar(model: model)
            Divider()
            Group {
                switch model.section {
                case .overview: OverviewSection(model: model)
                case .structure: StructureSection(model: model)
                case .partitions: PartitionsSection(model: model)
                case .statistics: StatisticsSection(model: model)
                case .ddl: DDLSection(model: model)
                case .data: DataSection(model: model)
                case .grants: GrantsSection(model: model)
                case .definition: DDLSection(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $model.inspected) { ValueInspectorView(value: $0) }
        .confirmationDialog(model.pendingRefresh == true ? "Refresh concurrently?" : "Refresh materialized view?",
                            isPresented: Binding(get: { model.pendingRefresh != nil }, set: { if !$0 { model.pendingRefresh = nil } }),
                            titleVisibility: .visible) {
            Button("Refresh", role: .destructive) {
                if let concurrently = model.pendingRefresh { model.refreshMaterializedView(concurrently: concurrently) }
                model.pendingRefresh = nil
            }
        } message: {
            Text(model.pendingRefresh == true
                 ? "REFRESH MATERIALIZED VIEW CONCURRENTLY rebuilds the data without blocking readers."
                 : "REFRESH MATERIALIZED VIEW takes an exclusive lock: queries on the view wait until it finishes.")
        }
    }
}

// MARK: - Header

private struct ObjectHeader: View {
    let model: ObjectDetailModel

    var body: some View {
        let reference = model.reference
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: reference.icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(reference.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                    if let relation = model.relation {
                        if relation.isPartition { Badge(text: "partition", color: Theme.color(for: .partitionedTable)) }
                        if relation.isHypertable { Badge(text: "hypertable", color: .orange) }
                        if let placement = relation.citusPlacement { Badge(text: "Citus \(placement.rawValue)", color: .teal) }
                        if relation.isUnlogged { Badge(text: "unlogged", color: .secondary) }
                    }
                }
                HStack(spacing: 6) {
                    Text(kindName)
                    Text("·")
                    Text([reference.database, reference.schema].compactMap { $0 }.joined(separator: " · "))
                    if let bound = model.relation?.partitionBound { Text("· \(bound)").lineLimit(1) }
                    if let comment = comment, !comment.isEmpty { Text("· \(comment)").lineLimit(1) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let relation = model.relation, relation.kind != .sequence {
                Button { model.openQuery() } label: { Label("Query", systemImage: "play.rectangle") }
                    .help("Open a SQL editor with SELECT * FROM \(relation.name)")
            }
            Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload this object's details")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var tint: Color {
        switch model.reference {
        case let .relation(relation, _): Theme.color(for: relation.kind)
        case .routine: Theme.routineColor
        case .type: Theme.typeColor
        case .extensionInfo: .secondary
        }
    }

    private var kindName: String {
        switch model.reference {
        case let .relation(relation, _): relation.kind.displayName
        case let .routine(routine, _): routine.kind.displayName
        case let .type(type, _): type.kind.displayName
        case .extensionInfo: "Extension"
        }
    }

    private var comment: String? {
        switch model.reference {
        case let .relation(relation, _): relation.comment
        case let .routine(routine, _): routine.comment
        case let .type(type, _): type.comment
        case let .extensionInfo(info, _): info.comment
        }
    }
}

private struct SectionBar: View {
    let model: ObjectDetailModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(model.availableSections) { section in
                let selected = model.section == section
                Button {
                    model.select(section)
                } label: {
                    Label(section.rawValue, systemImage: section.icon)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Theme.accent : .secondary)
                        .background(selected ? Theme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Shows loading / error / content for a `Loadable`.
struct LoadableView<Value, Content: View>: View {
    let state: Loadable<Value>
    var retry: (() -> Void)?
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                ErrorBanner(message: message)
                if let retry { Button("Try Again", action: retry) }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .loaded(value):
            content(value)
        }
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    let model: ObjectDetailModel

    var body: some View {
        switch model.reference {
        case let .relation(relation, _):
            LoadableView(state: model.overview, retry: model.loadOverview) { overview in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let statistics = overview.statistics { SizeCards(statistics: statistics, relation: relation) }
                        if relation.kind == .partitionedTable {
                            NoticeBanner(message: "Partitioned tables store no rows themselves; sizes and statistics live on the partitions (\(Format.bytes(relation.totalBytes)) in total).",
                                         systemImage: "square.split.2x2", color: Theme.color(for: .partitionedTable))
                        }
                        if let info = overview.materializedView { MaterializedViewCard(model: model, info: info) }
                        if let sequence = overview.sequence { SequenceCard(info: sequence) }
                        if let hypertable = overview.hypertable {
                            Card(title: "TimescaleDB hypertable", systemImage: "clock.arrow.2.circlepath") {
                                KeyValueList(items: [
                                    ("Chunks", Format.count(hypertable.chunkCount)),
                                    ("Dimensions", hypertable.dimensions.joined(separator: ", ")),
                                    ("Compression", hypertable.compressionEnabled ? "Enabled (\(hypertable.compressedChunks ?? 0) chunks compressed)" : "Off"),
                                    ("Total size", Format.bytes(hypertable.totalBytes)),
                                ])
                            }
                        }
                        if let placement = relation.citusPlacement {
                            Card(title: "Citus", systemImage: "point.3.connected.trianglepath.dotted") {
                                KeyValueList(items: [("Placement", placement.rawValue.capitalized),
                                                     ("Distribution column", relation.distributionColumn ?? "—")])
                            }
                        }
                        if !overview.spatial.isEmpty {
                            Card(title: "PostGIS columns", systemImage: "globe") {
                                KeyValueList(items: overview.spatial.map { ($0.column, "\($0.type) · SRID \($0.srid.map(String.init) ?? "?") · \($0.dimensions ?? 2)D") })
                            }
                        }
                        if let statistics = overview.statistics { MaintenanceCard(statistics: statistics) }
                    }
                    .padding(18)
                }
            }
        case let .routine(routine, _):
            LoadableView(state: model.function, retry: model.loadFunction) { detail in
                ScrollView {
                    Card(title: routine.signature, systemImage: Theme.icon(for: routine.kind)) {
                        KeyValueList(items: [
                            ("Kind", routine.kind.displayName), ("Returns", routine.result ?? "—"), ("Language", routine.language),
                            ("Volatility", routine.volatilityName), ("Security", routine.isSecurityDefiner ? "SECURITY DEFINER" : "SECURITY INVOKER"),
                            ("Strict", detail.isStrict ? "Yes (returns NULL on NULL input)" : "No"), ("Parallel", parallelName(detail.parallel)),
                            ("Cost", detail.cost.map { String(format: "%.0f", $0) } ?? "—"), ("Owner", detail.owner ?? "—"),
                        ])
                    }
                    .padding(18)
                }
            }
        case .type:
            LoadableView(state: model.typeDetail, retry: model.loadOverview) { detail in
                ScrollView {
                    Card(title: detail.summary.name, systemImage: Theme.icon(for: detail.summary.kind)) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(detail.summary.kind.displayName).foregroundStyle(.secondary)
                            if !detail.enumLabels.isEmpty {
                                FlowLabels(labels: detail.enumLabels)
                            }
                            if !detail.attributes.isEmpty { KeyValueList(items: detail.attributes.map { ($0.name, $0.type) }, monospacedValues: true) }
                            if let base = detail.baseType {
                                KeyValueList(items: [("Base type", base), ("Not null", detail.isNotNull ? "Yes" : "No"),
                                                     ("Default", detail.defaultExpression ?? "—")] + detail.constraints.map { ("Constraint", $0) })
                            }
                        }
                    }
                    .padding(18)
                }
            }
        case let .extensionInfo(info, _):
            ScrollView {
                Card(title: info.name, systemImage: "puzzlepiece.extension") {
                    KeyValueList(items: [("Installed version", info.installedVersion ?? "—"), ("Default version", info.defaultVersion ?? "—"),
                                         ("Schema", info.schema ?? "—"), ("Description", info.comment ?? "—")])
                    if info.hasUpdate {
                        NoticeBanner(message: "Version \(info.defaultVersion ?? "") is available: ALTER EXTENSION \(info.name) UPDATE;",
                                     systemImage: "arrow.up.circle", color: .orange)
                    }
                }
                .padding(18)
            }
        }
    }

    private func parallelName(_ code: String?) -> String {
        switch code {
        case "s": "Safe"
        case "r": "Restricted"
        case "u": "Unsafe"
        default: "—"
        }
    }
}

private struct FlowLabels: View {
    let labels: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                Badge(text: "\(index + 1). \(label)", color: Theme.typeColor)
            }
        }
    }
}

private struct SizeCards: View {
    let statistics: TableStatistics
    let relation: RelationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                StatTile(title: "Total size", value: Format.bytes(statistics.totalBytes), systemImage: "externaldrive")
                StatTile(title: "Estimated rows", value: Format.count(statistics.estimatedRows), systemImage: "number")
                StatTile(title: "Dead tuples", value: statistics.deadTupleRatio.map { Format.percent($0 * 100) } ?? "—",
                         systemImage: "trash", tint: (statistics.deadTupleRatio ?? 0) > 0.2 ? .orange : Theme.accent)
                StatTile(title: "Estimated bloat", value: statistics.bloat.map { "\(Format.bytes($0.wastedBytes)) (\(Format.percent($0.ratio * 100)))" } ?? "—",
                         systemImage: "bubbles.and.sparkles", tint: (statistics.bloat?.ratio ?? 0) > 0.3 ? .orange : Theme.accent)
            }
            SizeBreakdown(statistics: statistics)
        }
    }
}

/// Heap / TOAST / index split of the total size.
private struct SizeBreakdown: View {
    let statistics: TableStatistics

    var body: some View {
        let heap = Double(max(0, (statistics.heapBytes ?? 0)))
        let toast = Double(max(0, statistics.toastBytes ?? 0))
        let index = Double(max(0, statistics.indexBytes ?? 0))
        let total = max(heap + toast + index, 1)
        Card(title: "Storage", systemImage: "chart.bar.doc.horizontal") {
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    Rectangle().fill(Color(nsColor: .kindTable)).frame(width: proxy.size.width * heap / total)
                    Rectangle().fill(Color.orange).frame(width: proxy.size.width * toast / total)
                    Rectangle().fill(Color.purple).frame(width: proxy.size.width * index / total)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 12)
            HStack(spacing: 16) {
                legend(Color(nsColor: .kindTable), "Heap", statistics.heapBytes)
                legend(.orange, "TOAST", statistics.toastBytes)
                legend(.purple, "Indexes", statistics.indexBytes)
            }
            .font(.caption)
        }
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(Format.bytes(bytes)).monospacedDigit()
        }
    }
}

private struct MaintenanceCard: View {
    let statistics: TableStatistics

    var body: some View {
        Card(title: "Activity & maintenance", systemImage: "wrench.and.screwdriver") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    KeyValueList(items: [
                        ("Sequential scans", Format.count(statistics.sequentialScans)),
                        ("Index scans", Format.count(statistics.indexScans)),
                        ("Rows inserted", Format.count(statistics.inserted)),
                        ("Rows updated", "\(Format.count(statistics.updated)) (\(Format.count(statistics.hotUpdated)) HOT)"),
                        ("Rows deleted", Format.count(statistics.deleted)),
                        ("Cache hit ratio", statistics.cacheHitRatio.map { Format.percent($0 * 100) } ?? "—"),
                    ])
                    KeyValueList(items: [
                        ("Live / dead tuples", "\(Format.count(statistics.liveTuples)) / \(Format.count(statistics.deadTuples))"),
                        ("Last vacuum", relative(statistics.lastVacuumAny)),
                        ("Last analyze", relative(statistics.lastAnalyzeAny)),
                        ("Modified since analyze", Format.count(statistics.modifiedSinceAnalyze)),
                        ("Transaction ID age", Format.count(statistics.transactionIDAge)),
                        ("Options", statistics.options.isEmpty ? "—" : statistics.options.joined(separator: ", ")),
                    ])
                }
            }
            if let age = statistics.transactionIDAge, age > 1_000_000_000 {
                NoticeBanner(message: "The table's transaction-ID age is high; make sure autovacuum can freeze it before wraparound protection forces it.",
                             systemImage: "exclamationmark.triangle", color: .orange)
            }
        }
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct MaterializedViewCard: View {
    let model: ObjectDetailModel
    let info: MaterializedViewInfo

    var body: some View {
        Card(title: "Materialized view", systemImage: "square.stack.3d.up.fill") {
            KeyValueList(items: [("Populated", info.isPopulated ? "Yes" : "No (WITH NO DATA)"),
                                 ("Unique index", info.hasUniqueIndex ? "Yes" : "No")])
            HStack(spacing: 10) {
                Button {
                    model.pendingRefresh = false
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    model.pendingRefresh = true
                } label: {
                    Label("Refresh Concurrently", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(info.concurrentRefreshBlocker != nil)
                .help(info.concurrentRefreshBlocker ?? "Refresh without blocking readers")
                if model.actionInFlight { ProgressView().controlSize(.small) }
            }
            .disabled(model.actionInFlight)
            if let blocker = info.concurrentRefreshBlocker {
                Text(blocker).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SequenceCard: View {
    let info: SequenceInfo

    var body: some View {
        Card(title: "Sequence", systemImage: "number") {
            KeyValueList(items: [
                ("Type", info.dataType), ("Current value", info.lastValue.map { $0.formatted() } ?? "not used yet"),
                ("Increment", info.increment.map { $0.formatted() } ?? "—"),
                ("Range", "\(info.minValue.map { $0.formatted() } ?? "?") … \(info.maxValue.map { $0.formatted() } ?? "?")"),
                ("Cache", info.cache.map { $0.formatted() } ?? "—"), ("Cycles", info.cycles ? "Yes" : "No"), ("Owned by", info.ownedBy ?? "—"),
            ])
            if let used = info.usedFraction {
                ProgressView(value: used) {
                    Text("Headroom: \(Format.percent((1 - used) * 100)) of the range left")
                        .font(.caption)
                        .foregroundStyle(info.isNearlyExhausted ? .orange : .secondary)
                }
                .tint(info.isNearlyExhausted ? .orange : Theme.accent)
            }
        }
    }
}

// MARK: - Structure

private struct StructureSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.structure, retry: model.loadStructure) { structure in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card(title: "Columns (\(structure.columns.count))", systemImage: "list.bullet.rectangle") {
                        Table(structure.columns) {
                            TableColumn("#") { Text("\($0.number)").monospacedDigit().foregroundStyle(.secondary) }.width(28)
                            TableColumn("Name") { column in
                                HStack(spacing: 4) {
                                    Text(column.name).fontWeight(.medium)
                                    if !column.isLocal { Badge(text: "inherited", color: .secondary) }
                                }
                            }
                            TableColumn("Type") { Text($0.type).font(Theme.monospacedSmall) }
                            TableColumn("Null") { Text($0.isNullable ? "" : "NOT NULL").font(.caption).foregroundStyle(.secondary) }.width(70)
                            TableColumn("Default / generated") { column in
                                Text(column.identityDescription ?? column.generatedExpression.map { "GENERATED (\($0))" } ?? column.defaultExpression ?? "")
                                    .font(Theme.monospacedSmall).lineLimit(1)
                            }
                            TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .frame(minHeight: CGFloat(min(structure.columns.count, 14)) * 24 + 30)
                    }
                    if !structure.constraints.filter({ $0.kind != .notNull }).isEmpty {
                        Card(title: "Constraints", systemImage: "checkmark.shield") {
                            ForEach(structure.constraints.filter { $0.kind != .notNull }) { constraint in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Badge(text: constraint.kind.displayName, color: constraint.kind == .primaryKey ? Theme.accent : .secondary)
                                    Text(constraint.name).fontWeight(.medium)
                                    Text(constraint.definition).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
                                    if !constraint.isValidated { Badge(text: "NOT VALID", color: .orange) }
                                    if !constraint.isLocal { Badge(text: "inherited", color: .secondary) }
                                }
                            }
                        }
                    }
                    if !structure.indexes.isEmpty {
                        Card(title: "Indexes (\(structure.indexes.count))", systemImage: "magnifyingglass") {
                            ForEach(structure.indexes) { index in IndexRow(index: index) }
                        }
                    }
                    if !structure.triggers.isEmpty {
                        Card(title: "Triggers", systemImage: "bolt") {
                            ForEach(structure.triggers) { trigger in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(trigger.name).fontWeight(.medium)
                                        if !trigger.isEnabled { Badge(text: "disabled", color: .orange) }
                                    }
                                    Text(trigger.definition).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
        }
    }
}

private struct IndexRow: View {
    let index: IndexInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(index.name).fontWeight(.medium)
                Badge(text: index.method, color: .secondary)
                if index.isPrimary { Badge(text: "primary", color: Theme.accent) } else if index.isUnique { Badge(text: "unique", color: .teal) }
                if !index.isValid { Badge(text: "INVALID", color: .red, systemImage: "xmark.octagon") }
                if index.isUnused { Badge(text: "unused", color: .orange, systemImage: "zzz").help("Never scanned since statistics were reset") }
                if let bloat = index.bloat, bloat.ratio > 0.3 {
                    Badge(text: "~\(Format.percent(bloat.ratio * 100)) bloat", color: .orange).help("Estimated from statistics; REINDEX CONCURRENTLY reclaims it")
                }
                Spacer()
                Text(Format.bytes(index.sizeBytes)).monospacedDigit().foregroundStyle(.secondary)
                Text("\(Format.count(index.scans)) scans").monospacedDigit().foregroundStyle(.secondary)
            }
            Text(index.definition).font(Theme.monospacedSmall).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Partitions

private struct PartitionsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.partitioning, retry: model.loadPartitions) { info in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if let key = info.partitionKey { Badge(text: "PARTITION BY \(key)", color: Theme.color(for: .partitionedTable)) }
                    if let parent = info.parent { Text("Parent: \(parent)").foregroundStyle(.secondary) }
                    Spacer()
                    Text("\(info.children.count) \(info.partitionKey == nil && info.parent == nil ? "children" : "partitions") · \(Format.bytes(info.children.compactMap(\.totalBytes).reduce(0, &+)))")
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                Divider()
                if info.children.isEmpty {
                    ContentUnavailableView("No Partitions", systemImage: "square.split.2x2",
                                           description: Text(info.parent != nil ? "This is a partition of \(info.parent ?? "")." : "No partitions or inheritance children."))
                } else {
                    let largest = max(info.children.compactMap(\.totalBytes).max() ?? 1, 1)
                    Table(info.children) {
                        TableColumn("Name") { child in
                            HStack(spacing: 4) {
                                Image(systemName: Theme.icon(for: child.kind ?? .table)).foregroundStyle(Theme.color(for: child.kind ?? .table))
                                Text(child.name)
                            }
                        }
                        TableColumn("Bound") { Text($0.bound ?? "inherits").font(Theme.monospacedSmall).lineLimit(1) }
                        TableColumn("Rows") { Text(Format.count($0.estimatedRows)).monospacedDigit() }.width(90)
                        TableColumn("Size") { child in
                            HStack {
                                ProgressView(value: Double(child.totalBytes ?? 0) / Double(largest)).frame(width: 60)
                                Text(Format.bytes(child.totalBytes)).monospacedDigit()
                            }
                        }.width(160)
                    }
                }
            }
        }
    }
}

// MARK: - Statistics

private struct StatisticsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.overview, retry: model.loadOverview) { overview in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let statistics = overview.statistics {
                        SizeCards(statistics: statistics, relation: model.relation ?? RelationSummary(oid: 0, schema: "", name: "", kind: .table))
                        MaintenanceCard(statistics: statistics)
                    }
                    if let structure = model.structure.value {
                        Card(title: "Index usage", systemImage: "magnifyingglass") {
                            let maxScans = max(structure.indexes.compactMap(\.scans).max() ?? 1, 1)
                            ForEach(structure.indexes) { index in
                                HStack(spacing: 10) {
                                    Text(index.name).frame(width: 220, alignment: .leading).lineLimit(1)
                                    ProgressView(value: Double(index.scans ?? 0) / Double(maxScans)).tint(index.isUnused ? .orange : Theme.accent)
                                    Text("\(Format.count(index.scans)) scans").monospacedDigit().frame(width: 110, alignment: .trailing)
                                    Text(Format.bytes(index.sizeBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    Text(index.bloat.map { "~\(Format.percent($0.ratio * 100)) bloat" } ?? "").foregroundStyle(.secondary)
                                        .frame(width: 100, alignment: .trailing)
                                }
                                .font(.callout)
                            }
                            Text("Bloat figures are estimates from planner statistics (ANALYZE keeps them current).").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding(18)
            }
        }
    }
}

// MARK: - DDL, data, grants

private struct DDLSection: View {
    let model: ObjectDetailModel
    @State private var selection = NSRange(location: 0, length: 0)

    var body: some View {
        LoadableView(state: model.ddl, retry: model.loadDDL) { ddl in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        Pasteboard.copy(ddl)
                        model.workspace.showToast("DDL copied")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.workspace.openSQL(text: ddl, database: model.database)
                    } label: {
                        Label("Open in Editor", systemImage: "square.and.pencil")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                SQLEditor(text: .constant(ddl), selection: $selection, isEditable: false, highlightsCurrentStatement: false)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .onAppear { model.loadDDL() }
    }
}

private struct DataSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.preview, retry: model.loadPreview) { result in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("First \(Format.count(result.rows.count)) rows").font(.callout.weight(.semibold))
                    Spacer()
                    Button { model.loadPreview() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button { model.openQuery() } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                Divider()
                ResultGrid(resultID: model.previewID, columns: result.columns, rows: result.rows,
                           insertTableName: model.relation?.qualifiedName ?? "exported", onInspect: { model.inspected = $0 })
            }
        }
    }
}

private struct GrantsSection: View {
    let model: ObjectDetailModel

    var body: some View {
        LoadableView(state: model.grants, retry: model.loadGrants) { grants in
            let byGrantee = Dictionary(grouping: grants, by: \.grantee)
            List {
                ForEach(byGrantee.keys.sorted(), id: \.self) { grantee in
                    HStack(alignment: .firstTextBaseline) {
                        Label(grantee, systemImage: grantee == "PUBLIC" ? "globe" : "person").frame(width: 200, alignment: .leading)
                        FlowLabels(labels: (byGrantee[grantee] ?? []).map { $0.privilege + ($0.isGrantable ? " ✳︎" : "") })
                    }
                }
            }
            .overlay { if grants.isEmpty { ContentUnavailableView("No Grants", systemImage: "person.badge.key") } }
        }
    }
}
