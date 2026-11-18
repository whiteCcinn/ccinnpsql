import CcinnPsqlKit
import SwiftUI

/// Settings → MCP: which connections AI clients may use, and how to register the server.
struct MCPSettingsView: View {
    let store: ProfileStore
    @State private var copied: String?
    @State private var roleReports: [UUID: RoleReport] = [:]

    private var command: String { MCPCommand.executablePath }

    /// A least-privilege role for AI connections (`pg_read_all_data` exists on PostgreSQL 14+). Not pg_monitor or
    /// pg_read_all_stats: they read every session's SQL, so read-only access refuses them by default.
    static let readerRoleSQL = """
        CREATE ROLE ai_reader LOGIN PASSWORD 'change-me';
        GRANT pg_read_all_data TO ai_reader;
        """

    private var snippets: [(title: String, text: String)] {
        let quoted = command.replacingOccurrences(of: "\"", with: "\\\"")
        return [
            ("Claude Code", "claude mcp add ccinnpsql -- \"\(quoted)\" mcp"),
            ("Codex (~/.codex/config.toml)", "[mcp_servers.ccinnpsql]\ncommand = \"\(quoted)\"\nargs = [\"mcp\"]"),
            ("Claude Desktop / JSON", "{\n  \"mcpServers\": {\n    \"ccinnpsql\": {\n      \"command\": \"\(quoted)\",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"),
        ]
    }

    var body: some View {
        Form {
            Section {
                Text("CcinnPsql includes a Model Context Protocol server, so AI assistants such as Claude Code, Codex and Claude Desktop can explore your databases and run queries through your saved connections. Passwords stay in your Keychain and are never shown to the AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Label {
                    Text("Read-only means no data or schema changes. Functions already defined in your database can still do what a read-only transaction allows (such as signalling other sessions), and no SQL check sees inside them. For real isolation, connect AI with a dedicated low-privilege role, not a superuser:")
                        .font(.callout)
                } icon: {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                }
                HStack(alignment: .top) {
                    Text(Self.readerRoleSQL)
                        .font(Theme.monospacedSmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied == "role" ? "Copied" : "Copy") {
                        Pasteboard.copy(Self.readerRoleSQL)
                        copied = "role"
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Text("pg_read_all_data needs PostgreSQL 14 or later; on older servers grant SELECT on the schemas the AI may read. Leave out pg_monitor and pg_read_all_stats: they let a role read every session's SQL, so read-only access refuses them unless you allow it below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Recommended: a dedicated role")
            }
            Section("Connections available to AI") {
                if store.profiles.isEmpty {
                    Text("No saved connections yet.").foregroundStyle(.secondary)
                }
                ForEach(store.profiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) { profile in
                    Picker(selection: Binding(get: { profile.mcpAccess }, set: { store.setMCPAccess($0, for: profile) })) {
                        ForEach(MCPAccess.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(Theme.color(for: profile.color).gradient).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName)
                                Text(profile.hostSummary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if profile.mcpAccess == .readOnly {
                        privilegedRoleControls(for: profile)
                    }
                }
                Text("Read-only allows metadata tools and SELECT / WITH / SHOW / EXPLAIN, checked by the app and run inside READ ONLY transactions with a statement timeout, at most 1,000 rows per call. Read & write adds a tool that runs any statement. Every call is logged (passwords redacted) to mcp-audit.jsonl in the app's data folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Before every read-only call, CcinnPsql checks the connection's role. A superuser, or a role that is (or can become) a member of pg_execute_server_program, pg_read_server_files or pg_write_server_files, can run programs on the server or read and write its files — through any function or SQL built at run time, which no read-only check can see and a READ ONLY transaction does not stop. Members of pg_read_all_stats, pg_read_all_settings or pg_monitor can read every session's SQL and every setting (such as a replication password in primary_conninfo). Read-only access refuses such a role unless you allow it for that connection. SECURITY DEFINER functions owned by such roles that the AI's role can call, and foreign tables it can read that run a server program or read a server file when read (file_fdw program / filename), are reported, not refused (extensions often install such functions): the check can't see inside them, so they remain an accepted risk. Functions in untrusted languages (internal, C, plpython3u, …) the role can execute, outside pg_catalog and reviewed extensions, are reported too and refused when called by name; that is best effort, since views, operators, casts, defaults and row security call functions implicitly, so the real control is a role without EXECUTE on them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Add the server to your AI client") {
                ForEach(snippets, id: \.title) { snippet in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(snippet.title).font(.callout.weight(.semibold))
                            Spacer()
                            Button(copied == snippet.title ? "Copied" : "Copy") {
                                Pasteboard.copy(snippet.text)
                                copied = snippet.title
                            }
                            .controlSize(.small)
                        }
                        Text(snippet.text)
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Text("Add `--read-only` after `mcp` to cap every connection at read-only, or `--profile <name>` to pick the default connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 560)
    }

    /// The per-connection opt-in for privileged roles, and a check of what the role can reach.
    @ViewBuilder
    private func privilegedRoleControls(for profile: ConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Allow AI read-only access on a privileged role",
                   isOn: Binding(get: { profile.mcpAllowPrivilegedRole }, set: { store.setMCPAllowPrivilegedRole($0, for: profile) }))
                .toggleStyle(.checkbox)
                .help("Off by default. A superuser or a member of pg_execute_server_program / pg_read_server_files / pg_write_server_files can run server programs or touch server files, and a member of pg_read_all_stats / pg_read_all_settings / pg_monitor can read every session's SQL and every setting; the read-only check can't prevent either.")
            HStack(spacing: 8) {
                Button(roleReports[profile.id] == .checking ? "Checking…" : "Check Role") { checkRole(of: profile) }
                    .controlSize(.small)
                    .disabled(roleReports[profile.id] == .checking)
                if let report = roleReports[profile.id], report != .checking {
                    Text(report.summary).font(.caption).foregroundStyle(report.isWarning ? Color.orange : Color.secondary).textSelection(.enabled)
                }
            }
        }
        .padding(.leading, 17)
    }

    private func checkRole(of profile: ConnectionProfile) {
        roleReports[profile.id] = .checking
        let password = store.password(for: profile) ?? ""
        let sshSecret = profile.ssh.map { $0.authentication == .agent } == false ? store.sshSecret(for: profile) : nil
        Task {
            let report: RoleReport
            do {
                let client = try await ConnectionOpener.open(profile: profile, password: password, sshSecret: sshSecret, progress: { _ in })
                defer { Task { await client.close() } }
                report = .checked(try await PostgresMCPTools.inspectRole(client, database: nil))
            } catch {
                report = .failed(describe(error))
            }
            roleReports[profile.id] = report
        }
    }
}

/// What "Check Role" found for a connection.
private enum RoleReport: Equatable {
    case checking
    case checked(MCPRoleCheck)
    case failed(String)

    var isWarning: Bool {
        switch self {
        case let .checked(check):
            check.isPrivileged || check.securityDefinerCount > 0 || check.fileTableCount > 0 || check.untrustedCount > 0
                || check.refusal(.allowPrivileged) != nil
        case .failed: true
        case .checking: false
        }
    }

    var summary: String {
        switch self {
        case .checking: return ""
        case let .failed(message): return "Could not check: \(message)"
        case let .checked(check):
            var parts: [String] = []
            if let refusal = check.refusal(.allowPrivileged) { parts.append(refusal) }
            parts.append(check.isPrivileged ? "Privileged: reaches \(check.privilegedRoles.joined(separator: ", "))." : "Not privileged.")
            if let encoding = check.singleByteEncoding {
                parts.append("Single-byte encoding \(encoding): names in AI statements must be ASCII or quoted.")
            }
            if check.securityDefinerCount > 0 {
                parts.append("\(check.securityDefinerCount) callable SECURITY DEFINER functions owned by privileged roles: "
                    + MCPRoleCheck.listing(check.securityDefiners, of: check.securityDefinerCount) + ".")
            }
            if check.fileTableCount > 0 {
                parts.append("\(check.fileTableCount) readable foreign tables that run a server program or read a server file when read: "
                    + MCPRoleCheck.listing(check.fileTables, of: check.fileTableCount) + ".")
            }
            if check.untrustedCount > 0 {
                parts.append("\(check.untrustedCount) callable functions in untrusted languages (direct calls refused; revoke EXECUTE to stop views "
                    + "and other implicit calls): " + MCPRoleCheck.listing(check.untrustedFunctions, of: check.untrustedCount) + ".")
            }
            if check.foreignTableCount > 0 {
                parts.append("\(check.foreignTableCount) readable foreign tables of other wrappers: "
                    + MCPRoleCheck.listing(check.foreignTables, of: check.foreignTableCount) + ".")
            }
            return parts.joined(separator: " ")
        }
    }
}
