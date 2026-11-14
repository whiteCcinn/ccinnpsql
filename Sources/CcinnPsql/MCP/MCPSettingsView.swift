import CcinnPsqlKit
import SwiftUI

/// Settings → MCP: which connections AI clients may use, and how to register the server.
struct MCPSettingsView: View {
    let store: ProfileStore
    @State private var copied: String?

    private var command: String { MCPCommand.executablePath }

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
                }
                Text("Read-only allows metadata tools and SELECT / WITH / SHOW / EXPLAIN, checked by the app and run inside READ ONLY transactions with a statement timeout, at most 1,000 rows per call. Read & write adds a tool that runs any statement. Every call is logged (passwords redacted) to mcp-audit.jsonl in the app's data folder.")
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
}
