import CcinnPsqlKit
import Foundation
import Observation
import PostgresKit

struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

/// A browsable object and the database it lives in.
enum ObjectReference: Hashable, Sendable {
    case relation(RelationSummary, database: String)
    case routine(RoutineSummary, database: String)
    case type(TypeSummary, database: String)
    case extensionInfo(ExtensionSummary, database: String)

    var database: String {
        switch self {
        case let .relation(_, database), let .routine(_, database), let .type(_, database), let .extensionInfo(_, database): database
        }
    }

    var name: String {
        switch self {
        case let .relation(relation, _): relation.name
        case let .routine(routine, _): routine.name
        case let .type(type, _): type.name
        case let .extensionInfo(info, _): info.name
        }
    }

    var schema: String? {
        switch self {
        case let .relation(relation, _): relation.schema
        case let .routine(routine, _): routine.schema
        case let .type(type, _): type.schema
        case let .extensionInfo(info, _): info.schema
        }
    }

    var icon: String {
        switch self {
        case let .relation(relation, _): Theme.icon(for: relation.kind)
        case let .routine(routine, _): Theme.icon(for: routine.kind)
        case let .type(type, _): Theme.icon(for: type.kind)
        case .extensionInfo: "puzzlepiece.extension"
        }
    }

    /// Identity for tab de-duplication (OIDs are per database).
    var key: String {
        switch self {
        case let .relation(relation, database): "r:\(database):\(relation.oid)"
        case let .routine(routine, database): "f:\(database):\(routine.oid)"
        case let .type(type, database): "t:\(database):\(type.oid)"
        case let .extensionInfo(info, database): "e:\(database):\(info.name)"
        }
    }
}

/// One tab in the workspace.
struct WorkspaceTab: Identifiable, Equatable {
    enum Kind {
        case object(ObjectDetailModel)
        case sql(SQLTabModel)
        case operations(OperationsModel)
        case notifications(NotificationsModel)
    }

    let id = UUID()
    let kind: Kind

    static func == (lhs: WorkspaceTab, rhs: WorkspaceTab) -> Bool { lhs.id == rhs.id }

    @MainActor var title: String {
        switch kind {
        case let .object(model): model.reference.name
        case let .sql(model): model.title
        case .operations: "Server"
        case .notifications: "LISTEN / NOTIFY"
        }
    }

    @MainActor var subtitle: String? {
        switch kind {
        case let .object(model): [model.reference.database, model.reference.schema].compactMap { $0 }.joined(separator: " · ")
        case let .sql(model): model.database
        case .operations: nil
        case let .notifications(model): model.database
        }
    }

    @MainActor var icon: String {
        switch kind {
        case let .object(model): model.reference.icon
        case .sql: "chevron.left.forwardslash.chevron.right"
        case .operations: "waveform.path.ecg"
        case .notifications: "bell.badge"
        }
    }
}

/// Everything a connected window shows: database and schema tree, open tabs, and caches shared by tabs.
@MainActor
@Observable
final class WorkspaceModel {
    enum SchemaState {
        case loading
        case loaded(SchemaContents)
        case failed(String)
    }

    let profile: ConnectionProfile
    let client: PostgresClient
    let history: QueryHistoryStore

    private(set) var currentDatabase: String
    var databases: [DatabaseSummary] = []
    var schemas: [SchemaSummary] = []
    var isLoadingSchemas = false
    var schemasError: String?
    var schemaStates: [String: SchemaState] = [:]
    var expandedSchemas: Set<String> = []
    var showSystemSchemas = false
    var sidebarFilter = ""
    var extensions: [ExtensionSummary] = []

    var tabs: [WorkspaceTab] = []
    var selectedTabID: UUID?
    var toast: Toast?

    /// Columns per table (completion), per database.
    private var columnCache: [TableKey: [SchemaSnapshot.ColumnEntry]] = [:]
    private var columnMisses: [TableKey: Date] = [:]
    private var schemaLoads: [String: Task<Void, Never>] = [:]
    private var schemaLoadGenerations: [String: UInt64] = [:]
    private var schemaLoadGeneration: UInt64 = 0
    private var databaseGeneration: UInt64 = 0
    private var sqlTabCounter = 0
    private var toastTask: Task<Void, Never>?

    init(profile: ConnectionProfile, client: PostgresClient) {
        self.profile = profile
        self.client = client
        currentDatabase = client.defaultDatabase
        history = QueryHistoryStore(directory: AppServices.shared.historyDirectory, profileID: profile.id)
    }

    var serverInfo: ServerInfo { client.serverInfo }
    var versionLabel: String { serverInfo.productSummary }
    var isConsole: Bool { serverInfo.isPgBouncerConsole }

    var visibleSchemas: [SchemaSummary] {
        schemas.filter { showSystemSchemas || !$0.isSystem }
    }

    // MARK: Lifecycle

    func start() {
        guard !isConsole else { return }
        Task { await loadDatabases() }
        Task { await reloadSchemas() }
    }

    func shutdown() {
        for tab in tabs { closeResources(of: tab) }
        tabs.removeAll()
        let client = client
        Task.detached { await client.close() }
    }

    // MARK: Databases and schemas

    func loadDatabases() async {
        do {
            databases = try await client.databases().filter { !$0.isTemplate && $0.allowsConnections }
        } catch {
            showToast("Could not list databases: \(describe(error))", isError: true)
        }
    }

    func selectDatabase(_ name: String) {
        guard name != currentDatabase else { return }
        currentDatabase = name
        databaseGeneration &+= 1
        schemaStates.removeAll()
        expandedSchemas.removeAll()
        schemas = []
        extensions = []
        columnCache.removeAll()
        columnMisses.removeAll()
        for task in schemaLoads.values { task.cancel() }
        schemaLoads.removeAll()
        Task { await reloadSchemas() }
    }

    func reloadSchemas() async {
        guard !isConsole else { return }
        isLoadingSchemas = true
        defer { isLoadingSchemas = false }
        let database = currentDatabase
        let generation = databaseGeneration
        do {
            let loaded = try await client.schemas(database: database)
            guard generation == databaseGeneration else { return } // the user switched databases meanwhile
            schemas = loaded
            schemasError = nil
            if expandedSchemas.isEmpty {
                let preferred = loaded.first { $0.name == "public" } ?? loaded.first { !$0.isSystem }
                if let preferred { setExpanded(preferred.name, true) }
            }
            for schema in expandedSchemas where loaded.contains(where: { $0.name == schema }) {
                loadSchema(schema, force: true)
            }
            extensions = (try? await client.extensions(database: database).filter(\.isInstalled)) ?? []
        } catch {
            guard generation == databaseGeneration else { return }
            schemasError = describe(error)
        }
    }

    func refreshAll() {
        columnCache.removeAll()
        columnMisses.removeAll()
        Task {
            await loadDatabases()
            await reloadSchemas()
        }
    }

    func setExpanded(_ schema: String, _ expanded: Bool) {
        if expanded {
            expandedSchemas.insert(schema)
            if schemaStates[schema] == nil { loadSchema(schema) }
        } else {
            expandedSchemas.remove(schema)
        }
    }

    func loadSchema(_ schema: String, force: Bool = false) {
        if !force, let state = schemaStates[schema], case .loaded = state { return }
        if schemaLoads[schema] != nil, !force { return }
        if schemaStates[schema] == nil { schemaStates[schema] = .loading }
        let database = currentDatabase
        let databaseGeneration = databaseGeneration
        schemaLoadGeneration &+= 1
        let generation = schemaLoadGeneration
        schemaLoads[schema]?.cancel()
        let client = client
        schemaLoads[schema] = Task {
            // Only the newest load for this schema may publish its result or clear the slot (stale results are dropped).
            defer { if schemaLoadGenerations[schema] == generation { schemaLoads[schema] = nil } }
            do {
                let contents = try await client.schemaContents(schema, database: database)
                guard databaseGeneration == self.databaseGeneration, schemaLoadGenerations[schema] == generation else { return }
                schemaStates[schema] = .loaded(contents)
            } catch {
                guard databaseGeneration == self.databaseGeneration, schemaLoadGenerations[schema] == generation, !Task.isCancelled else { return }
                schemaStates[schema] = .failed(describe(error))
            }
        }
        schemaLoadGenerations[schema] = generation
    }

    func awaitSchema(_ schema: String) async -> SchemaContents? {
        if case let .loaded(contents)? = schemaStates[schema] { return contents }
        loadSchema(schema)
        while let task = schemaLoads[schema] {
            await task.value
            if schemaLoads[schema] == task { break }
        }
        if case let .loaded(contents)? = schemaStates[schema] { return contents }
        return nil
    }

    func contents(of schema: String) -> SchemaContents? {
        if case let .loaded(contents)? = schemaStates[schema] { return contents }
        return nil
    }

    func relation(schema: String, name: String) -> RelationSummary? {
        contents(of: schema)?.relations.first { $0.name == name }
    }

    // MARK: Completion schema

    /// Completion metadata for `database` (sidebar data is only used when it belongs to that database).
    func completionSnapshot(database: String, searchPath: [String]) -> SchemaSnapshot {
        guard database == currentDatabase else { return SchemaSnapshot(searchPath: searchPath) }
        var objects: [String: [SchemaSnapshot.ObjectEntry]] = [:]
        var functions: [String: [RoutineSummary]] = [:]
        for (schema, state) in schemaStates {
            if case let .loaded(contents) = state {
                objects[schema] = contents.relations.map { SchemaSnapshot.ObjectEntry(name: $0.name, kind: $0.kind) }
                functions[schema] = contents.routines
            }
        }
        return SchemaSnapshot(searchPath: searchPath, schemas: schemas.map(\.name), objectsBySchema: objects, columnsByTable: columnCache,
                              functionsBySchema: functions)
    }

    /// Loads what completion reported as missing. Tables that do not exist are remembered for a minute so typing
    /// does not re-query them (negative cache).
    func ensureSchema(columns keys: [TableKey], schemas missingSchemas: [String], database: String) async {
        guard database == currentDatabase else { return }
        for schema in Set(missingSchemas) where schemas.contains(where: { $0.name.caseInsensitiveCompare(schema) == .orderedSame }) {
            _ = await awaitSchema(schemas.first { $0.name.caseInsensitiveCompare(schema) == .orderedSame }?.name ?? schema)
        }
        let now = Date()
        let wanted = Set(keys).filter { key in
            columnCache[key] == nil && (columnMisses[key].map { now.timeIntervalSince($0) > 60 } ?? true)
        }
        guard !wanted.isEmpty else { return }
        for key in wanted { columnMisses[key] = now } // in flight: do not ask again while loading
        let generation = databaseGeneration
        guard let loaded = try? await client.columnsByTable(wanted.map { ($0.schema, $0.table) }, database: database),
              generation == databaseGeneration else { return }
        for key in wanted {
            if let columns = loaded["\(key.schema).\(key.table)"] {
                columnCache[key] = columns.map { SchemaSnapshot.ColumnEntry(name: $0.name, type: $0.type) }
                columnMisses[key] = nil
            }
        }
    }

    // MARK: Tabs

    var selectedTab: WorkspaceTab? { tabs.first { $0.id == selectedTabID } }

    var selectedSQL: SQLTabModel? {
        if case let .sql(model)? = selectedTab?.kind { return model }
        return nil
    }

    func open(_ reference: ObjectReference, section: ObjectDetailModel.Section? = nil) {
        if let existing = tabs.first(where: { if case let .object(model) = $0.kind { model.reference.key == reference.key } else { false } }) {
            selectedTabID = existing.id
            if let section, case let .object(model) = existing.kind { model.select(section) }
            return
        }
        let model = ObjectDetailModel(reference: reference, workspace: self)
        if let section { model.select(section) }
        let tab = WorkspaceTab(kind: .object(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    @discardableResult
    func openSQL(text: String = "", database: String? = nil, run: Bool = false) -> SQLTabModel {
        sqlTabCounter += 1
        let model = SQLTabModel(title: "Query \(sqlTabCounter)", text: text, database: database ?? contextDatabase, workspace: self)
        let tab = WorkspaceTab(kind: .sql(model))
        tabs.append(tab)
        selectedTabID = tab.id
        if run { model.runAll() }
        return model
    }

    func openOperations(section: OperationsModel.Section = .overview) {
        if let existing = tabs.first(where: { if case .operations = $0.kind { true } else { false } }) {
            selectedTabID = existing.id
            if case let .operations(model) = existing.kind { model.section = section }
            return
        }
        let model = OperationsModel(workspace: self, section: section)
        let tab = WorkspaceTab(kind: .operations(model))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func openNotifications() {
        if let existing = tabs.first(where: { if case .notifications = $0.kind { true } else { false } }) {
            selectedTabID = existing.id
            return
        }
        let tab = WorkspaceTab(kind: .notifications(NotificationsModel(workspace: self, database: currentDatabase)))
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func close(_ tab: WorkspaceTab) {
        guard let index = tabs.firstIndex(of: tab) else { return }
        closeResources(of: tab)
        tabs.remove(at: index)
        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    func closeSelectedTab() {
        if let selectedTab { close(selectedTab) }
    }

    func selectTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func moveTab(_ id: UUID, to target: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == target }), from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    private func closeResources(of tab: WorkspaceTab) {
        switch tab.kind {
        case let .sql(model): model.close()
        case let .operations(model): model.close()
        case let .notifications(model): model.close()
        case .object: break
        }
    }

    /// Database for new SQL tabs: the open object's, the current tab's, or the sidebar's.
    private var contextDatabase: String {
        switch selectedTab?.kind {
        case let .object(model)?: model.reference.database
        case let .sql(model)?: model.database
        default: currentDatabase
        }
    }

    // MARK: Feedback

    func showToast(_ message: String, isError: Bool = false) {
        toast = Toast(message: message, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(isError ? 5 : 2.5))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }
}
