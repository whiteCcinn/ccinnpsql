import AppKit
import CcinnPsqlKit
import PostgresKit
import SwiftUI

struct CcinnPsqlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        // Every window has its own connection. A request opens a window that connects right away.
        WindowGroup("CcinnPsql", id: RootView.windowGroupID, for: WindowRequest.self) { $request in
            RootView(request: request)
                .frame(minWidth: 1040, minHeight: 640)
                .preferredColorScheme(LaunchArguments.appearanceOverride ?? AppearancePreference(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            AppCommands()
            UpdateCommands()
        }

        Settings {
            SettingsTabs()
            .frame(width: 620)
            .tint(Theme.accent)
        }

        SoftwareUpdateScene()
    }
}

private struct SettingsTabs: View {
    @AppStorage("settingsTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            SettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MCPSettingsView(store: AppServices.shared.profiles)
                .tabItem { Label("MCP", systemImage: "sparkles") }
                .tag("mcp")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Restored windows would only reopen the connection screen; start with one clean window.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SnapshotTool.isRequested, !LaunchArguments.has("--snapshot-visible") {
            // Visual checks run invisibly: no Dock icon, no focus stealing, transparent windows.
            NSApp.setActivationPolicy(.accessory)
        } else {
            // Behave like a regular app when launched from `swift run` (no bundle).
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        if let scheme = LaunchArguments.appearanceOverride {
            NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        }
        SnapshotTool.scheduleIfRequested()
        UpdateController.shared.scheduleAutomaticCheck()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Close SSH port forwards synchronously; detached cleanup tasks do not run during exit.
        SSHTunnel.terminateAll()
    }
}

/// Per-window root: connection manager, progress, or workspace.
struct RootView: View {
    static let windowGroupID = "main"

    /// Set when the window was opened for a connection (Open in New Window, New Window with This Connection).
    let request: WindowRequest?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var session = WindowSession()
    private let store = AppServices.shared.profiles

    var body: some View {
        Group {
            switch session.phase {
            case .connections:
                ConnectionsView(session: session, store: store)
                    .transition(.opacity)
            case let .connecting(name, status):
                ConnectingView(name: name, status: status) { session.cancelConnecting() }
                    .transition(.opacity)
            case let .connected(workspace):
                WorkspaceView(workspace: workspace, session: session)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: phaseKey)
        .focusedSceneValue(\.windowSession, session)
        .navigationTitle(windowTitle)
        .presentsSoftwareUpdates()
        .onDisappear { session.disconnect() }
        .task {
            // A window this process opened for a connection connects; any other window (⌘N, or one macOS restored)
            // takes the plain path below.
            if session.connect(request, store: store) { return }
            LaunchArguments.consume(into: session, store: store) { openWindow(id: Self.windowGroupID, value: $0) }
            if let tab = LaunchArguments.value("--settings") {
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                try? await Task.sleep(for: .milliseconds(800))
                openSettings()
            }
        }
    }

    private var phaseKey: Int {
        switch session.phase {
        case .connections: 0
        case .connecting: 1
        case .connected: 2
        }
    }

    private var windowTitle: String {
        switch session.phase {
        case .connections: "CcinnPsql — Connections"
        case let .connecting(name, _): "Connecting to \(name)"
        case let .connected(workspace): workspace.profile.displayName
        }
    }
}

/// Full-window progress while a connection is being established.
struct ConnectingView: View {
    let name: String
    let status: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 64).symbolEffect(.pulse)
            Text("Connecting to \(name)").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.default, value: status)
            }
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Developer conveniences, deep links and automated visual checks:
///
///     CcinnPsql --profile <saved name>
///     CcinnPsql --connect host:port [--user u] [--database db] [--sslmode prefer] [--object schema.name]
///               [--section overview|structure|partitions|statistics|ddl|data|grants] [--sql "…"] [--auto-run]
///               [--view grid|chart|plan] [--explain] [--operations activity|locks|replication|…] [--notifications]
///               [--duplicate-window] [--format]
///     … [--appearance light|dark] [--settings mcp] [--snapshot out.png --snapshot-delay 6 --quit-after-snapshot]
///
/// The password for `--connect` comes from the environment (`CCINNPSQL_PASSWORD`), never the command line.
@MainActor
enum LaunchArguments {
    private static var consumed = false

    nonisolated static var arguments: [String] { ProcessInfo.processInfo.arguments }
    nonisolated static func has(_ flag: String) -> Bool { arguments.contains(flag) }
    nonisolated static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    nonisolated static var appearanceOverride: ColorScheme? {
        switch value("--appearance")?.lowercased() {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Applies the launch arguments to the first window, once per process. `openWindow` opens another window for a
    /// request (`--duplicate-window`).
    static func consume(into session: WindowSession, store: ProfileStore, openWindow: @escaping @MainActor (WindowRequest) -> Void) {
        guard !consumed else { return }
        consumed = true
        let profile: ConnectionProfile
        var password: String?
        if let name = value("--profile"), let saved = store.profiles.first(where: { $0.displayName == name }) {
            profile = saved
        } else if let raw = value("--connect") {
            let parts = raw.split(separator: ":")
            let host = parts.first.map(String.init) ?? "127.0.0.1"
            let port = parts.count > 1 ? Int(parts[1]) ?? 5432 : 5432
            profile = ConnectionProfile(name: value("--name") ?? "\(host):\(port)", host: host, port: port, username: value("--user") ?? "postgres",
                                        database: value("--database") ?? "postgres",
                                        sslMode: value("--sslmode").flatMap(SSLMode.init(rawValue:)) ?? .prefer, color: .blue,
                                        connectTimeout: value("--connect-timeout").flatMap(Double.init) ?? 30)
            password = ProcessInfo.processInfo.environment["CCINNPSQL_PASSWORD"] ?? ""
        } else {
            return
        }
        session.connect(profile: profile, store: store, password: password) { workspace in
            if has("--duplicate-window"), let request = session.duplicateRequest() { openWindow(request) }
            Task { @MainActor in
                if let target = value("--object"), let dot = target.firstIndex(of: ".") {
                    let schema = String(target[..<dot])
                    let name = String(target[target.index(after: dot)...])
                    workspace.setExpanded(schema, true)
                    if let contents = await workspace.awaitSchema(schema), let relation = contents.relations.first(where: { $0.name == name }) {
                        let section = value("--section").flatMap { raw in
                            ObjectDetailModel.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }
                        }
                        workspace.open(.relation(relation, database: workspace.currentDatabase), section: section)
                    }
                }
                if let sql = value("--sql") {
                    let model = workspace.openSQL(text: sql.replacingOccurrences(of: "\\n", with: "\n"), database: value("--database"))
                    if has("--format") {
                        try? await Task.sleep(for: .milliseconds(300)) // let the editor attach so the edit is undoable
                        model.formatSQL()
                        for _ in 0..<100 where model.isFormatting { try? await Task.sleep(for: .milliseconds(20)) }
                    }
                    if has("--explain") {
                        model.explain(analyze: has("--analyze"))
                    } else if has("--auto-run") {
                        model.runAll()
                    }
                    if let view = value("--view"), let mode = StatementOutcome.ViewMode.allCases.first(where: { $0.rawValue.lowercased() == view.lowercased() }) {
                        for _ in 0..<100 where model.isRunning || model.outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                        model.selectedOutcome?.viewMode = mode
                    }
                }
                if let raw = value("--operations"),
                   let section = OperationsModel.Section.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) }) {
                    workspace.openOperations(section: section)
                }
                if has("--notifications") { workspace.openNotifications() }
            }
        }
    }
}

/// `--snapshot <file.png> [--snapshot-delay seconds] [--quit-after-snapshot] [--snapshot-window title]`: renders the window
/// with that title, else the key or frontmost window (the newest one, e.g. opened by `--duplicate-window`), into a PNG
/// without activating the app (accessory policy, transparent windows); needs no screen-recording permission.
@MainActor
enum SnapshotTool {
    nonisolated static var isRequested: Bool { LaunchArguments.value("--snapshot") != nil }

    static func scheduleIfRequested() {
        guard let path = LaunchArguments.value("--snapshot") else { return }
        if !LaunchArguments.has("--snapshot-visible") {
            // Keep every window transparent so the check never disturbs the user; views still render.
            Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated { for window in NSApp.windows where window.alphaValue != 0 { window.alphaValue = 0 } }
            }
        }
        let delay = LaunchArguments.value("--snapshot-delay").flatMap(Double.init) ?? 6
        let quit = LaunchArguments.has("--quit-after-snapshot")
        let wantedTitle = LaunchArguments.value("--snapshot-window")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Front to back: the newest window comes first even when the app is inactive and no window is key.
            let candidates = NSApp.orderedWindows.filter { $0.isVisible && $0.sheetParent == nil && $0.frame.width > 400 }
            let chosen = wantedTitle.flatMap { title in candidates.first { $0.title.localizedCaseInsensitiveContains(title) } }
                ?? candidates.first { $0.isKeyWindow } ?? candidates.first
            if let window = chosen, let data = render(window) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            if quit { NSApp.terminate(nil) }
        }
    }

    private static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    static func render(_ window: NSWindow) -> Data? {
        guard let view = window.contentView?.superview ?? window.contentView, let base = bitmap(of: view) else { return nil }
        guard let sheet = window.attachedSheet, let sheetView = sheet.contentView?.superview ?? sheet.contentView,
              let overlay = bitmap(of: sheetView) else {
            return base.representation(using: .png, properties: [:])
        }
        let size = view.bounds.size
        let composite = NSImage(size: size)
        composite.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        let origin = NSPoint(x: (size.width - sheetView.bounds.width) / 2, y: size.height - sheetView.bounds.height - 28)
        overlay.draw(in: NSRect(origin: origin, size: sheetView.bounds.size))
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("autoLimit") private var autoLimit = 1000
    @AppStorage("sqlFormatKeywordCase") private var formatKeywordCase = SQLFormatOptions.KeywordCase.upper.rawValue
    @AppStorage("sqlFormatIndent") private var formatIndent = 2

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Picker("Automatic LIMIT for SELECT", selection: $autoLimit) {
                Text("None").tag(0)
                ForEach([100, 500, 1000, 5000, 10_000, 50_000], id: \.self) { Text($0.formatted()).tag($0) }
            }
            Picker("Format SQL: keyword case", selection: $formatKeywordCase) {
                Text("UPPER").tag(SQLFormatOptions.KeywordCase.upper.rawValue)
                Text("lower").tag(SQLFormatOptions.KeywordCase.lower.rawValue)
                Text("Unchanged").tag(SQLFormatOptions.KeywordCase.preserve.rawValue)
            }
            .help("Applies to keywords only; names, functions, strings and quoted identifiers always keep their text.")
            Picker("Format SQL: indent", selection: $formatIndent) {
                Text("2 spaces").tag(2)
                Text("4 spaces").tag(4)
            }
            LabeledContent("Saved connections") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([ProfileRepository.defaultDirectory])
                }
            }
            UpdateSettingsSections()
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: - Commands

struct WindowSessionKey: FocusedValueKey {
    typealias Value = WindowSession
}

extension FocusedValues {
    var windowSession: WindowSession? {
        get { self[WindowSessionKey.self] }
        set { self[WindowSessionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @FocusedValue(\.windowSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            // File ▸ New Window (⌘N) comes from the window group and opens the connection screen.
            Button("New Window with This Connection") {
                if let request = session?.duplicateRequest() { openWindow(id: RootView.windowGroupID, value: request) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(session?.workspace == nil)
            Divider()
            Button("New Query") { session?.workspace?.openSQL() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(session?.workspace == nil)
            Button("Disconnect") { session?.disconnect() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Format SQL") { session?.workspace?.selectedSQL?.formatSQL() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedSQL == nil)
        }
        CommandMenu("Server") {
            Button("Refresh Schemas") { session?.workspace?.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Overview") { session?.workspace?.openOperations(section: .overview) }
                .disabled(session?.workspace == nil)
            Button("Activity") { session?.workspace?.openOperations(section: .activity) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(session?.workspace == nil)
            Button("Locks") { session?.workspace?.openOperations(section: .locks) }
                .disabled(session?.workspace == nil)
            Button("Replication") { session?.workspace?.openOperations(section: .replication) }
                .disabled(session?.workspace == nil)
            Button("Top Statements") { session?.workspace?.openOperations(section: .statements) }
                .disabled(session?.workspace == nil)
            Button("LISTEN / NOTIFY") { session?.workspace?.openNotifications() }
                .disabled(session?.workspace == nil)
            Divider()
            Button("Close Tab") { session?.workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(session?.workspace?.selectedTab == nil)
            Button("Next Tab") { session?.workspace?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
            Button("Previous Tab") { session?.workspace?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(session?.workspace == nil)
        }
    }
}
