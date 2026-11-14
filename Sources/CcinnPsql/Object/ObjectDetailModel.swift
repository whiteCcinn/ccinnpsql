import CcinnPsqlKit
import Foundation
import Observation
import PostgresKit

enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case let .loaded(value) = self { return value }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Everything shown about a table-like relation in one load (overview + statistics).
struct RelationOverview {
    var statistics: TableStatistics?
    var materializedView: MaterializedViewInfo?
    var sequence: SequenceInfo?
    var hypertable: HypertableInfo?
    var spatial: [SpatialColumn] = []
}

/// Columns, constraints, indexes and triggers.
struct RelationStructure {
    var columns: [ColumnInfo]
    var constraints: [ConstraintInfo]
    var indexes: [IndexInfo]
    var triggers: [TriggerInfo]
}

/// State of one object tab. Sections load lazily and independently; stale loads are discarded (generation tokens).
@MainActor
@Observable
final class ObjectDetailModel {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case structure = "Structure"
        case partitions = "Partitions"
        case statistics = "Statistics"
        case ddl = "DDL"
        case data = "Data"
        case grants = "Grants"
        case definition = "Definition"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overview: "info.circle"
            case .structure: "list.bullet.rectangle"
            case .partitions: "square.split.2x2"
            case .statistics: "gauge.with.dots.needle.33percent"
            case .ddl: "doc.plaintext"
            case .data: "tablecells"
            case .grants: "person.badge.key"
            case .definition: "curlybraces"
            }
        }
    }

    let reference: ObjectReference
    unowned let workspace: WorkspaceModel
    private(set) var section: Section = .overview

    var overview: Loadable<RelationOverview> = .idle
    var structure: Loadable<RelationStructure> = .idle
    var partitioning: Loadable<PartitioningInfo> = .idle
    var ddl: Loadable<String> = .idle
    var preview: Loadable<ResultSet> = .idle
    var previewID = UUID()
    var grants: Loadable<[GrantInfo]> = .idle
    var function: Loadable<FunctionDetail> = .idle
    var typeDetail: Loadable<TypeDetail> = .idle
    var actionInFlight = false
    var inspected: InspectedValue?
    var pendingRefresh: Bool?
    private var generation: UInt64 = 0

    init(reference: ObjectReference, workspace: WorkspaceModel) {
        self.reference = reference
        self.workspace = workspace
        load(availableSections.first ?? .overview)
    }

    var client: PostgresClient { workspace.client }
    var database: String { reference.database }

    var relation: RelationSummary? {
        if case let .relation(relation, _) = reference { return relation }
        return nil
    }

    var availableSections: [Section] {
        switch reference {
        case let .relation(relation, _):
            switch relation.kind {
            case .table, .foreignTable:
                return relation.isPartition || relation.hasChildren
                    ? [.overview, .structure, .partitions, .statistics, .ddl, .data, .grants]
                    : [.overview, .structure, .statistics, .ddl, .data, .grants]
            case .partitionedTable: return [.overview, .structure, .partitions, .ddl, .data, .grants]
            case .materializedView: return [.overview, .structure, .statistics, .ddl, .data, .grants]
            case .view: return [.structure, .ddl, .data, .grants]
            case .sequence: return [.overview, .ddl, .grants]
            }
        case .routine: return [.overview, .definition]
        case .type: return [.overview]
        case .extensionInfo: return [.overview]
        }
    }

    func select(_ section: Section) {
        guard availableSections.contains(section) else { return }
        self.section = section
        load(section)
    }

    func reload() {
        generation &+= 1
        overview = .idle
        structure = .idle
        partitioning = .idle
        ddl = .idle
        preview = .idle
        grants = .idle
        function = .idle
        typeDetail = .idle
        load(section)
    }

    func load(_ section: Section) {
        self.section = availableSections.contains(section) ? section : (availableSections.first ?? .overview)
        switch self.section {
        case .overview: loadOverview()
        case .structure: loadStructure()
        case .partitions: loadPartitions()
        case .statistics: loadOverview(); loadStructure()
        case .ddl: loadDDL()
        case .data: loadPreview()
        case .grants: loadGrants()
        case .definition: loadFunction()
        }
    }

    /// Runs `work` and publishes its result only if no reload happened meanwhile.
    private func fetch<T: Sendable>(_ keyPath: ReferenceWritableKeyPath<ObjectDetailModel, Loadable<T>>, force: Bool = false,
                                    _ work: @escaping @Sendable () async throws -> T) {
        if !force, case .loaded = self[keyPath: keyPath] { return }
        if self[keyPath: keyPath].isLoading { return }
        self[keyPath: keyPath] = .loading
        let token = generation
        Task {
            do {
                let value = try await work()
                guard token == generation else { return }
                self[keyPath: keyPath] = .loaded(value)
            } catch {
                guard token == generation else { return }
                self[keyPath: keyPath] = .failed(describe(error))
            }
        }
    }

    func loadOverview() {
        switch reference {
        case let .relation(relation, database):
            let client = client
            fetch(\.overview) {
                var overview = RelationOverview()
                switch relation.kind {
                case .table, .materializedView, .foreignTable:
                    if relation.kind != .foreignTable { overview.statistics = try await client.statistics(of: relation, database: database) }
                    if relation.kind == .materializedView { overview.materializedView = try await client.materializedViewInfo(relation, database: database) }
                case .partitionedTable:
                    overview.statistics = nil
                case .sequence:
                    overview.sequence = try await client.sequenceInfo(relation, database: database)
                case .view:
                    break
                }
                if relation.isHypertable { overview.hypertable = try? await client.hypertableInfo(relation, database: database) }
                if client.serverInfo.extensionNamed("postgis") != nil || relation.kind.isTableLike {
                    overview.spatial = (try? await client.spatialColumns(relation, database: database)) ?? []
                }
                return overview
            }
        case .routine:
            loadFunction()
        case let .type(type, database):
            let client = client
            fetch(\.typeDetail) { try await client.typeDetail(type, database: database) }
        case .extensionInfo:
            break
        }
    }

    func loadStructure() {
        guard let relation else { return }
        let (client, database) = (client, database)
        fetch(\.structure) {
            let columns = try await client.columns(of: relation, database: database)
            guard relation.kind != .view else { return RelationStructure(columns: columns, constraints: [], indexes: [], triggers: []) }
            async let constraints = client.constraints(of: relation, database: database)
            async let indexes = client.indexes(of: relation, columns: columns, database: database)
            async let triggers = client.triggers(of: relation, database: database)
            return RelationStructure(columns: columns, constraints: try await constraints, indexes: try await indexes, triggers: try await triggers)
        }
    }

    func loadPartitions() {
        guard let relation else { return }
        let (client, database) = (client, database)
        fetch(\.partitioning) { try await client.partitioning(of: relation, database: database) }
    }

    func loadDDL() {
        let (client, database) = (client, database)
        switch reference {
        case let .relation(relation, _):
            fetch(\.ddl) { try await client.ddl(for: relation, database: database) }
        case let .routine(routine, _):
            fetch(\.ddl) { try await client.functionDetail(routine, database: database).definition ?? "-- No definition (aggregate or internal function)" }
        default:
            break
        }
    }

    func loadPreview() {
        guard let relation else { return }
        let (client, database) = (client, database)
        previewID = UUID()
        fetch(\.preview, force: true) {
            guard let result = try await client.preview(relation, limit: 200, database: database).lastRowSet else {
                throw PostgresError(.protocolViolation, "No rows were returned")
            }
            return result
        }
    }

    func loadGrants() {
        guard let relation else { return }
        let (client, database) = (client, database)
        fetch(\.grants) { try await client.grants(of: relation, database: database) }
    }

    func loadFunction() {
        guard case let .routine(routine, database) = reference else { return }
        let client = client
        fetch(\.function) { try await client.functionDetail(routine, database: database) }
    }

    func openQuery() {
        guard let relation else { return }
        workspace.openSQL(text: "SELECT *\nFROM \(relation.qualifiedName)\nLIMIT 100;", database: database, run: true)
    }

    /// Refreshes a materialized view (confirmed by the view first).
    func refreshMaterializedView(concurrently: Bool) {
        guard let relation, relation.kind == .materializedView, !actionInFlight else { return }
        actionInFlight = true
        let (client, database) = (client, database)
        Task {
            defer { actionInFlight = false }
            do {
                try await client.refreshMaterializedView(relation, concurrently: concurrently, database: database)
                workspace.showToast("Refreshed \(relation.name)")
                overview = .idle
                preview = .idle
                load(section)
            } catch {
                workspace.showToast("Refresh failed: \(describe(error))", isError: true)
            }
        }
    }
}
