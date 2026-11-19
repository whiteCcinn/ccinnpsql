import CcinnPsqlKit
import PostgresKit
import SwiftUI

/// Database switcher → schemas → relations (partitions nested under their parent), routines, types; plus the
/// installed extensions. Filtering and context actions.
struct SidebarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
            if workspace.isConsole {
                consoleNotice
            } else {
                List(selection: $selection) {
                    if let error = workspace.schemasError {
                        ErrorBanner(message: error).listRowSeparator(.hidden)
                    }
                    ForEach(visibleSchemas) { schema in
                        SchemaRow(workspace: workspace, schema: schema.name, isSystem: schema.isSystem, filter: filter)
                    }
                    if workspace.isLoadingSchemas, workspace.schemas.isEmpty {
                        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                    }
                    if !workspace.extensions.isEmpty, filter.isEmpty {
                        Section("Extensions") {
                            ForEach(workspace.extensions) { item in
                                HStack(spacing: 6) {
                                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary).frame(width: 18)
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    if item.hasUpdate {
                                        Image(systemName: "arrow.up.circle").foregroundStyle(.orange).help("Update available: \(item.defaultVersion ?? "")")
                                    }
                                    Text(item.installedVersion ?? "").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                }
                                .tag("e:" + item.name)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, id in
                    guard let id, let reference = find(id) else { return }
                    workspace.open(reference)
                }
            }
        }
        .placedBelowWindowToolbar()
    }

    private var filter: String { workspace.sidebarFilter.trimmingCharacters(in: .whitespaces) }

    private var consoleNotice: some View {
        VStack(spacing: 10) {
            NoticeBanner(message: "Connected to the PgBouncer admin console. It has no schemas; use the Server tab for SHOW POOLS, STATS, CLIENTS and SERVERS, or run SHOW commands in a query tab.",
                         systemImage: "arrow.triangle.branch", color: .orange)
            Button("Open Pooler Reports") { workspace.openOperations(section: .pooler) }
            Spacer()
        }
        .padding(10)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            if !workspace.isConsole {
                Menu {
                    ForEach(workspace.databases) { database in
                        Button {
                            workspace.selectDatabase(database.name)
                        } label: {
                            if database.name == workspace.currentDatabase {
                                Label(database.name, systemImage: "checkmark")
                            } else {
                                Text("\(database.name)  ·  \(Format.bytes(database.sizeBytes))")
                            }
                        }
                    }
                } label: {
                    Label(workspace.currentDatabase, systemImage: "cylinder.split.1x2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .help("Database")
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter tables, views, functions", text: $workspace.sidebarFilter)
                    .textFieldStyle(.plain)
                if !workspace.sidebarFilter.isEmpty {
                    Button { workspace.sidebarFilter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
                Toggle(isOn: $workspace.showSystemSchemas) { Image(systemName: "gearshape.2") }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Show system schemas")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var visibleSchemas: [SchemaSummary] {
        let schemas = workspace.visibleSchemas
        guard !filter.isEmpty else { return schemas }
        return schemas.filter { schema in
            schema.name.localizedCaseInsensitiveContains(filter) || SchemaRow.matches(workspace.contents(of: schema.name), filter: filter)
        }
    }

    /// Selection tags: `r:schema:oid`, `f:schema:oid`, `t:schema:oid`, `e:name`.
    private func find(_ id: String) -> ObjectReference? {
        let parts = id.split(separator: ":", maxSplits: 2).map(String.init)
        let database = workspace.currentDatabase
        if parts.first == "e", parts.count == 2 {
            return workspace.extensions.first { $0.name == parts[1] }.map { .extensionInfo($0, database: database) }
        }
        guard parts.count == 3, let oid = UInt32(parts[2]), let contents = workspace.contents(of: parts[1]) else { return nil }
        switch parts[0] {
        case "r": return contents.relations.first { $0.oid == oid }.map { .relation($0, database: database) }
        case "f": return contents.routines.first { $0.oid == oid }.map { .routine($0, database: database) }
        case "t": return contents.types.first { $0.oid == oid }.map { .type($0, database: database) }
        default: return nil
        }
    }
}

private struct SchemaRow: View {
    let workspace: WorkspaceModel
    let schema: String
    let isSystem: Bool
    let filter: String

    static func matches(_ contents: SchemaContents?, filter: String) -> Bool {
        guard let contents else { return false }
        return contents.relations.contains { $0.name.localizedCaseInsensitiveContains(filter) }
            || contents.routines.contains { $0.name.localizedCaseInsensitiveContains(filter) }
            || contents.types.contains { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { workspace.expandedSchemas.contains(schema) || (!filter.isEmpty && Self.matches(workspace.contents(of: schema), filter: filter)) },
                                            set: { workspace.setExpanded(schema, $0) })) {
            content
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSystem ? "folder.badge.gearshape" : "folder")
                    .foregroundStyle(isSystem ? Color.secondary : Theme.accent)
                Text(schema).lineLimit(1)
                Spacer()
                if let count = workspace.contents(of: schema)?.relations.count {
                    Text("\(count)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .contextMenu {
                Button("New Query") {
                    workspace.openSQL(text: "SET search_path TO \(SQLText.identifier(schema)), public;\n\n", database: workspace.currentDatabase)
                }
                Button("Refresh") { workspace.loadSchema(schema, force: true) }
                if !KnowledgeSQL.systemSchemas.contains(schema) {
                    Button("Knowledge") { workspace.openKnowledge(schema: schema) }
                }
                Divider()
                Button("Copy Name") { Pasteboard.copy(schema) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch workspace.schemaStates[schema] {
        case nil, .loading?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message)?:
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                Button("Retry") { workspace.loadSchema(schema, force: true) }.buttonStyle(.link).font(.caption)
            }
        case let .loaded(contents)?:
            let groups = self.groups(contents)
            if groups.isEmpty {
                Text(filter.isEmpty ? "Empty schema" : "No matches").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(groups, id: \.title) { group in
                Text("\(group.title.uppercased())  \(group.count)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                    .selectionDisabled()
                ForEach(group.nodes) { node in
                    RelationTreeRow(node: node, schema: schema, workspace: workspace, depth: 0, filter: filter)
                }
                ForEach(group.routines) { routine in
                    HStack(spacing: 6) {
                        Image(systemName: Theme.icon(for: routine.kind)).foregroundStyle(Theme.routineColor).frame(width: 18)
                        Text(routine.name).lineLimit(1)
                        Text("(\(routine.arguments))").font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                    }
                    .help(routine.signature + (routine.result.map { " → \($0)" } ?? ""))
                    .tag("f:\(schema):\(routine.oid)")
                }
                ForEach(group.types) { type in
                    HStack(spacing: 6) {
                        Image(systemName: Theme.icon(for: type.kind)).foregroundStyle(Theme.typeColor).frame(width: 18)
                        Text(type.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(type.kind.displayName).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .tag("t:\(schema):\(type.oid)")
                }
            }
        }
    }

    private struct Group {
        let title: String
        var nodes: [RelationNode] = []
        var routines: [RoutineSummary] = []
        var types: [TypeSummary] = []
        var count: Int { nodes.count + routines.count + types.count }
    }

    private func groups(_ contents: SchemaContents) -> [Group] {
        func keep(_ name: String) -> Bool { filter.isEmpty || name.localizedCaseInsensitiveContains(filter) }
        func keepNode(_ node: RelationNode) -> Bool { keep(node.relation.name) || node.children.contains(where: keepNode) }
        let tree = contents.tree
        var result: [Group] = []
        let tables = tree.filter { $0.relation.kind.isTableLike && keepNode($0) }
        if !tables.isEmpty { result.append(Group(title: "Tables", nodes: tables)) }
        let views = tree.filter { $0.relation.kind == .view && keepNode($0) }
        if !views.isEmpty { result.append(Group(title: "Views", nodes: views)) }
        let materialized = tree.filter { $0.relation.kind == .materializedView && keepNode($0) }
        if !materialized.isEmpty { result.append(Group(title: "Materialized views", nodes: materialized)) }
        let sequences = contents.relations(of: .sequence).filter { keep($0.name) }.map { RelationNode(relation: $0) }
        if !sequences.isEmpty { result.append(Group(title: "Sequences", nodes: sequences)) }
        let functions = contents.routines.filter { $0.kind != .procedure && keep($0.name) }
        if !functions.isEmpty { result.append(Group(title: "Functions", routines: functions)) }
        let procedures = contents.routines.filter { $0.kind == .procedure && keep($0.name) }
        if !procedures.isEmpty { result.append(Group(title: "Procedures", routines: procedures)) }
        let types = contents.types.filter { keep($0.name) }
        if !types.isEmpty { result.append(Group(title: "Types", types: types)) }
        return result
    }
}

/// A relation row with its partitions / inheritance children disclosed beneath it.
private struct RelationTreeRow: View {
    let node: RelationNode
    let schema: String
    let workspace: WorkspaceModel
    let depth: Int
    let filter: String
    @State private var expanded = false

    var body: some View {
        if node.children.isEmpty || depth > 12 {
            RelationRow(relation: node.relation, workspace: workspace)
                .tag("r:\(schema):\(node.relation.oid)")
        } else {
            DisclosureGroup(isExpanded: Binding(get: { expanded || !filter.isEmpty }, set: { expanded = $0 })) {
                ForEach(node.children) { child in
                    RelationTreeRow(node: child, schema: schema, workspace: workspace, depth: depth + 1, filter: filter)
                }
            } label: {
                RelationRow(relation: node.relation, workspace: workspace, childCount: node.children.count)
                    .tag("r:\(schema):\(node.relation.oid)")
            }
        }
    }
}

private struct RelationRow: View {
    let relation: RelationSummary
    let workspace: WorkspaceModel
    var childCount = 0

    var body: some View {
        HStack(spacing: 6) {
            RelationIcon(relation: relation)
            Text(relation.name).lineLimit(1).truncationMode(.middle)
            if relation.isHypertable { Badge(text: "hypertable", color: .orange) }
            if let placement = relation.citusPlacement { Badge(text: placement.rawValue, color: .teal) }
            if relation.isUnlogged { Badge(text: "unlogged", color: .secondary) }
            if childCount > 0 {
                Text("\(childCount) part\(childCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if relation.kind != .sequence, let rows = relation.estimatedRows, rows > 0 {
                Text(rows.formatted(.number.notation(.compactName))).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .help(help)
        .contextMenu {
            let reference = ObjectReference.relation(relation, database: workspace.currentDatabase)
            Button("Open") { workspace.open(reference) }
            if relation.kind != .sequence {
                Button("Query in New Tab") {
                    workspace.openSQL(text: "SELECT *\nFROM \(relation.qualifiedName)\nLIMIT 100;", database: workspace.currentDatabase, run: true)
                }
                Button("Columns & Indexes") { workspace.open(reference, section: .structure) }
                Button("Statistics") { workspace.open(reference, section: .statistics) }
            }
            Button("DDL") { workspace.open(reference, section: .ddl) }
            Divider()
            Button("Copy Name") { Pasteboard.copy(relation.name) }
            Button("Copy Qualified Name") { Pasteboard.copy(relation.qualifiedName) }
        }
    }

    private var help: String {
        var parts = [relation.isPartition ? "Partition" : relation.kind.displayName]
        if let bound = relation.partitionBound { parts.append(bound) }
        if let bytes = relation.totalBytes { parts.append(Format.bytes(bytes)) }
        if let comment = relation.comment, !comment.isEmpty { parts.append(comment) }
        return parts.joined(separator: " · ")
    }
}
