import CcinnPsqlKit
import PostgresKit
import SwiftUI

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    let session: WindowSession
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(workspace: workspace)
                .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 460)
        } detail: {
            VStack(spacing: 0) {
                if !workspace.tabs.isEmpty {
                    TabBarView(workspace: workspace)
                    Divider()
                }
                ZStack {
                    if let tab = workspace.selectedTab {
                        TabContentView(tab: tab)
                            .id(tab.id)
                    } else {
                        WorkspaceHome(workspace: workspace)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottom) { ToastView(toast: workspace.toast) }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionBadge(workspace: workspace)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("New Window with This Connection", action: openDuplicateWindow)
                    Button("New Window") { openWindow(id: RootView.windowGroupID) }
                } label: {
                    Label("New Window", systemImage: "macwindow.badge.plus")
                } primaryAction: {
                    openDuplicateWindow()
                }
                .help("Open this connection in another window (⇧⌘N); each window has its own connection")
                Button {
                    workspace.openSQL()
                } label: {
                    Label("New Query", systemImage: "plus.rectangle.on.rectangle")
                }
                .help("New SQL editor (⌘T)")
                Button {
                    workspace.openOperations(section: .activity)
                } label: {
                    Label("Activity", systemImage: "bolt.horizontal.circle")
                }
                .help("Sessions, wait events and the blocking tree")
                Button {
                    workspace.openOperations(section: .overview)
                } label: {
                    Label("Server", systemImage: "server.rack")
                }
                .help("Server overview, locks, replication, statements, settings and roles")
                Button {
                    workspace.openNotifications()
                } label: {
                    Label("LISTEN / NOTIFY", systemImage: "bell.badge")
                }
                .help("Listen to notification channels")
                .disabled(!workspace.serverInfo.keepsSessionState)
                Button {
                    workspace.refreshAll()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload databases, schemas and objects (⇧⌘R)")
                Button {
                    session.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "eject")
                }
                .help("Disconnect (⇧⌘D)")
            }
        }
    }

    private func openDuplicateWindow() {
        if let request = session.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
    }
}

private struct ConnectionBadge: View {
    let workspace: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.color(for: workspace.profile.color).gradient)
                .frame(width: 10, height: 10)
            Text(workspace.profile.displayName).font(.headline).lineLimit(1)
            Badge(text: workspace.versionLabel, color: Theme.accent)
            if workspace.serverInfo.isInRecovery {
                Badge(text: "Standby", color: .orange, systemImage: "arrow.triangle.2.circlepath")
            }
            if workspace.serverInfo.pooler != .none {
                Badge(text: workspace.serverInfo.poolingMode == .transaction ? "Transaction pooler" : "Pooler", color: .orange,
                      systemImage: "arrow.triangle.branch")
                    .help(workspace.serverInfo.poolingDetail)
            }
            if let tls = workspace.serverInfo.tlsDescription {
                Badge(text: tls, color: .green, systemImage: "lock.fill")
            } else {
                Badge(text: "Unencrypted", color: .secondary, systemImage: "lock.open")
            }
            if workspace.client.isTunnelled {
                Badge(text: "SSH", color: .purple, systemImage: "lock.shield")
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Content of the selected tab.
struct TabContentView: View {
    let tab: WorkspaceTab

    var body: some View {
        switch tab.kind {
        case let .object(model): ObjectDetailView(model: model)
        case let .sql(model): SQLWorkbenchView(model: model)
        case let .operations(model): OperationsView(model: model)
        case let .knowledge(model): KnowledgeTabView(model: model)
        case let .notifications(model): NotificationsView(model: model)
        }
    }
}

struct ToastView: View {
    let toast: Toast?

    var body: some View {
        Group {
            if let toast {
                Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .foregroundStyle(toast.isError ? Color.red : Color.primary)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .frame(maxWidth: 640)
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.35), value: toast)
    }
}

/// Shown when no tab is open.
private struct WorkspaceHome: View {
    let workspace: WorkspaceModel

    var body: some View {
        VStack(spacing: 22) {
            AppLogo(size: 72)
            VStack(spacing: 6) {
                Text(workspace.profile.displayName).font(.title.weight(.semibold))
                Text([workspace.versionLabel, workspace.serverInfo.currentUser + "@" + workspace.currentDatabase,
                      workspace.serverInfo.isSuperuser ? "superuser" : nil].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
            }
            if workspace.serverInfo.poolingMode == .transaction {
                NoticeBanner(message: "Transaction pooling: SET, LISTEN, temporary tables and session-level advisory locks do not survive between transactions. Run related statements inside BEGIN … COMMIT.",
                             systemImage: "arrow.triangle.branch", color: .orange)
                    .frame(maxWidth: 560)
            }
            Text("Pick a table in the sidebar to see its columns, indexes, statistics and DDL.")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button { workspace.openSQL() } label: { Label("New Query", systemImage: "chevron.left.forwardslash.chevron.right") }
                Button { workspace.openOperations(section: .activity) } label: { Label("Activity", systemImage: "bolt.horizontal.circle") }
                Button { workspace.openOperations(section: .overview) } label: { Label("Server", systemImage: "server.rack") }
            }
            .controlSize(.large)
            HStack(spacing: 18) {
                ForEach([RelationKind.table, .partitionedTable, .view, .materializedView, .foreignTable, .sequence], id: \.self) { kind in
                    HStack(spacing: 4) {
                        Image(systemName: Theme.icon(for: kind)).foregroundStyle(Theme.color(for: kind))
                        Text(kind.displayName)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tab strip with close buttons, option-click close and drag reordering.
struct TabBarView: View {
    @Bindable var workspace: WorkspaceModel
    @State private var hovered: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(workspace.tabs) { tab in
                    TabButton(tab: tab, isSelected: workspace.selectedTabID == tab.id, isHovered: hovered == tab.id,
                              onSelect: { workspace.selectedTabID = tab.id },
                              onClose: { withAnimation(.snappy) { workspace.close(tab) } })
                        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
                        .draggable(tab.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                            withAnimation(.snappy) { workspace.moveTab(id, to: tab.id) }
                            return true
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

private struct TabButton: View {
    let tab: WorkspaceTab
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.icon)
                .foregroundStyle(isSelected ? Theme.accent : .secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                if let subtitle = tab.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isSelected || isHovered ? 1 : 0)
            .help("Close tab")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(isHovered ? Color.primary.opacity(0.06) : .clear))
                .shadow(color: .black.opacity(isSelected ? 0.08 : 0), radius: 1.5, y: 0.5)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onClose))
        .help(tab.subtitle.map { "\($0).\(tab.title)" } ?? tab.title)
    }
}
