import CcinnPsqlKit
import PostgresKit
import PostgresWire
import SwiftUI

struct SQLWorkbenchView: View {
    @Bindable var model: SQLTabModel

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchToolbar(model: model)
            Divider()
            VSplitView {
                VStack(spacing: 0) {
                    SQLEditor(text: $model.text, selection: $model.selection, diagnostics: model.diagnostics,
                              completionProvider: { [model] text, cursor in await model.completions(text: text, cursor: cursor) },
                              onEdit: { [model] edits in model.editorDidEdit(edits) },
                              focusOnAppear: true, controller: model.editorController)
                    DiagnosticsBar(model: model)
                }
                .frame(minHeight: 110, idealHeight: 260)
                .background(Color(nsColor: .textBackgroundColor))
                ResultPanel(model: model)
                    .frame(minHeight: 150, idealHeight: 380)
            }
        }
        .sheet(item: $model.inspected) { ValueInspectorView(value: $0) }
        .confirmationDialog(model.pendingConfirmation?.title ?? "Run statements that change data or schema?",
                            isPresented: Binding(get: { model.pendingConfirmation != nil }, set: { if !$0 { model.resolveConfirmation(false) } }),
                            titleVisibility: .visible) {
            Button("Run", role: .destructive) { model.resolveConfirmation(true) }
            Button("Cancel", role: .cancel) { model.resolveConfirmation(false) }
        } message: {
            Text((model.pendingConfirmation?.statements ?? []).prefix(5).map { String($0.prefix(160)) }.joined(separator: "\n\n"))
        }
    }
}

private struct WorkbenchToolbar: View {
    @Bindable var model: SQLTabModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.runCurrent()
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Run the selection or the statement under the cursor (⌘↩)")
            .disabled(model.isRunning)

            Button {
                model.runAll()
            } label: {
                Label("Run All", systemImage: "forward.end.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("Run every statement in the editor (⇧⌘↩)")
            .disabled(model.isRunning)

            Button {
                model.runScript()
            } label: {
                Label("Script", systemImage: "doc.text")
            }
            .help("Send the editor (or selection) as one script and show every result set")
            .disabled(model.isRunning)

            Menu {
                Button("Explain") { model.explain(analyze: false) }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Explain Analyze (with buffers)") { model.explain(analyze: true) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            } label: {
                Label("Explain", systemImage: "list.bullet.indent")
            } primaryAction: {
                model.explain(analyze: false)
            }
            .fixedSize()
            .disabled(model.isRunning || model.isConsole)
            .help("Show the query plan (⌘E); ⇧⌘E runs EXPLAIN ANALYZE, BUFFERS")

            Button {
                model.formatSQL()
            } label: {
                Label("Format", systemImage: "text.alignleft")
            }
            .disabled(model.isFormatting)
            .help("Format the selection, or the whole script when nothing is selected (⌥⌘L)")

            if model.isRunning {
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
                .tint(.red)
                .help("Cancel the running statement (⌘.)")
            }

            Divider().frame(height: 18)

            DatabaseMenu(model: model)

            Menu {
                ForEach([100, 500, 1000, 5000, 10_000, 50_000], id: \.self) { limit in
                    Button {
                        model.autoLimit = limit
                    } label: {
                        if model.autoLimit == limit { Label("\(limit.formatted()) rows", systemImage: "checkmark") } else { Text("\(limit.formatted()) rows") }
                    }
                }
                Divider()
                Button {
                    model.autoLimit = 0
                } label: {
                    if model.autoLimit == 0 { Label("No automatic limit", systemImage: "checkmark") } else { Text("No automatic limit") }
                }
            } label: {
                Label(model.autoLimit > 0 ? "Limit \(model.autoLimit.formatted())" : "No limit", systemImage: "line.3.horizontal.decrease")
            }
            .fixedSize()
            .help("Rows fetched by SELECT statements without their own LIMIT")

            TransactionBadge(model: model)

            Spacer()

            if let progress = model.exportProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                    Button { model.cancelExport() } label: { Image(systemName: "xmark.circle.fill") }.help("Cancel export")
                }
            }

            if let started = model.runStartedAt {
                TimelineView(.periodic(from: started, by: 0.1)) { context in
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(Format.duration(milliseconds: context.date.timeIntervalSince(started) * 1000))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                model.showHistory.toggle()
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .popover(isPresented: $model.showHistory, arrowEdge: .bottom) {
                HistoryPanel(model: model)
            }
            .help("Query history")
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

private struct DatabaseMenu: View {
    let model: SQLTabModel

    var body: some View {
        Menu {
            ForEach(model.workspace.databases) { database in
                Button {
                    model.use(database: database.name)
                } label: {
                    if model.database == database.name { Label(database.name, systemImage: "checkmark") } else { Text(database.name) }
                }
            }
        } label: {
            Label(model.database, systemImage: "cylinder.split.1x2")
        }
        .fixedSize()
        .disabled(model.isConsole)
        .help("Database of this editor's session")
    }
}

/// Shows whether the session is inside a transaction (and whether it is aborted).
private struct TransactionBadge: View {
    let model: SQLTabModel

    var body: some View {
        switch model.transactionStatus {
        case .idle:
            if model.lostTransaction {
                Badge(text: "Transaction lost", color: .red, systemImage: "bolt.slash")
                    .help("The connection dropped while a transaction was open; the server rolled it back.")
            }
        case .inTransaction:
            Badge(text: "In transaction", color: .blue, systemImage: "arrow.triangle.branch")
                .help("COMMIT or ROLLBACK to end the transaction.")
        case .failedTransaction:
            Badge(text: "Transaction aborted", color: .red, systemImage: "exclamationmark.triangle.fill")
                .help("A statement failed inside the transaction; run ROLLBACK before continuing.")
        }
    }
}

// MARK: - Diagnostics

/// A status line under the editor, always present so the editor never resizes: the diagnostic at the cursor (position,
/// message, navigation) and the cursor's own line and column.
private struct DiagnosticsBar: View {
    let model: SQLTabModel
    /// The diagnostic last navigated to; disambiguates diagnostics that start at the same offset.
    @State private var preferred: SQLDiagnostic?

    var body: some View {
        let diagnostics = model.diagnostics
        let cursor = model.selection.location
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if let index = SQLDiagnosticNavigator.currentIndex(in: diagnostics, cursor: cursor, preferred: preferred) {
                    problem(diagnostics, index)
                }
                Spacer(minLength: 8)
                let position = model.position(of: cursor)
                Text("Ln \(position.line), Col \(position.column)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func problem(_ diagnostics: [SQLDiagnostic], _ index: Int) -> some View {
        let diagnostic = diagnostics[index]
        let position = model.position(of: diagnostic.range.lowerBound)
        Image(systemName: diagnostic.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.orange)
        Text("Line \(position.line), column \(position.column)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        Text(diagnostic.message)
            .truncationMode(.tail)
            .help(diagnostic.message)
        Text(diagnostic.source == .server ? "PostgreSQL" : "Syntax check")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help(diagnostic.source == .server ? "Reported by PostgreSQL when the statement ran"
                                               : "Found while typing; nothing was sent to the server")
        if diagnostics.count > 1 {
            Text("\(index + 1) of \(diagnostics.count)").monospacedDigit().foregroundStyle(.secondary)
            Button {
                go(to: diagnostics[(index + diagnostics.count - 1) % diagnostics.count])
            } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous problem")
            Button {
                go(to: diagnostics[(index + 1) % diagnostics.count])
            } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next problem")
        } else {
            Button("Show") { go(to: diagnostic) }
                .help("Select the marked text in the editor")
        }
    }

    private func go(to diagnostic: SQLDiagnostic) {
        preferred = diagnostic
        model.reveal(diagnostic)
    }
}

/// A failed statement: error kind with its **editor** position, SQLSTATE and condition name, the message, and Show in
/// Editor while the marker is valid. Copy copies the whole error (message, SQLSTATE, detail and hint).
private struct StatementErrorView: View {
    let message: String
    let outcome: StatementOutcome
    let model: SQLTabModel

    var body: some View {
        let parsed = outcome.serverError ?? SQLServerError(message: message)
        let marker = model.serverDiagnostic(for: outcome)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                // Only an editor position: the server's is relative to the text sent.
                Text(parsed.title(at: marker.map { model.position(of: $0.range.lowerBound) })).font(.headline)
                if let state = parsed.sqlState {
                    Text([state, parsed.conditionName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                        .help("SQLSTATE")
                }
                Spacer()
                if let marker {
                    Button("Show in Editor") { model.reveal(marker) }
                        .help("Select the text this error is about")
                }
                Button {
                    Pasteboard.copy(message)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy error")
            }
            Text(parsed.summary)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint = parsed.hint, !hint.isEmpty {
                Label(SQLServerError.shortenedForDisplay(hint), systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

// MARK: - Results

struct ResultPanel: View {
    @Bindable var model: SQLTabModel

    var body: some View {
        VStack(spacing: 0) {
            if model.outcomes.isEmpty {
                ResultPlaceholder()
            } else {
                if model.outcomes.count > 1 {
                    OutcomeStrip(model: model)
                    Divider()
                }
                if let outcome = model.selectedOutcome {
                    OutcomeView(outcome: outcome, model: model)
                        .id(outcome.id)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ResultPlaceholder: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.and.command.macwindow")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Run a statement to see results").font(.headline).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                hint("⌘↩", "Run selection or current statement")
                hint("⇧⌘↩", "Run all statements")
                hint("⌘E", "Explain the current statement (⇧⌘E: ANALYZE)")
                hint("⌥⌘L", "Format the selection or the whole script")
                hint("⌃Space", "Suggest tables, columns and functions")
                hint("⌘/", "Toggle line comments")
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .gridColumnAlignment(.trailing)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct OutcomeStrip: View {
    let model: SQLTabModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.outcomes) { outcome in
                    let isSelected = model.selectedOutcome?.id == outcome.id
                    Button {
                        model.selectedOutcomeID = outcome.id
                    } label: {
                        HStack(spacing: 5) {
                            OutcomeStatusIcon(outcome: outcome)
                            Text("\(outcome.index + 1)").fontWeight(.semibold)
                            Text(outcome.summary).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(isSelected ? 0.6 : 0)))
                    }
                    .buttonStyle(.plain)
                    .help(outcome.sql)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }
}

private struct OutcomeStatusIcon: View {
    let outcome: StatementOutcome

    var body: some View {
        if outcome.isRunning {
            ProgressView().controlSize(.mini)
        } else if outcome.errorMessage != nil {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

private struct OutcomeView: View {
    @Bindable var outcome: StatementOutcome
    let model: SQLTabModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            OutcomeStatusIcon(outcome: outcome)
            Text(outcome.summary).font(.callout.weight(.semibold))
            if !outcome.isRunning {
                Text(Format.duration(milliseconds: outcome.durationMilliseconds))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let limit = outcome.limitApplied, let rows = outcome.rowSet?.rows.count, rows >= limit {
                Badge(text: "LIMIT \(limit.formatted()) added", color: .orange, systemImage: "line.3.horizontal.decrease")
                    .help("The statement had no LIMIT, so CcinnPsql fetched at most \(limit.formatted()) rows. Change it in the toolbar.")
            }
            if !outcome.notices.isEmpty {
                Badge(text: "\(outcome.notices.count) notice\(outcome.notices.count == 1 ? "" : "s")", color: .blue, systemImage: "text.bubble")
            }
            if !outcome.notifications.isEmpty {
                Badge(text: "\(outcome.notifications.count) NOTIFY", color: .purple, systemImage: "bell")
            }
            if outcome.rowSets.count > 1 {
                Picker("", selection: Binding(get: { outcome.selectedResultIndex ?? outcome.rowSets.count - 1 }, set: { outcome.selectedResultIndex = $0 })) {
                    ForEach(outcome.rowSets.indices, id: \.self) { index in Text("Result \(index + 1)").tag(index) }
                }
                .fixedSize()
                .help("This script returned several result sets")
            }
            if outcome.rowSet?.isTruncated == true {
                Badge(text: "Truncated at \(SQLTabModel.hardRowCap.formatted()) rows", color: .orange, systemImage: "scissors")
            }
            Spacer()
            if let rowSet = outcome.rowSet {
                Picker("", selection: $outcome.viewMode) {
                    Label("Grid", systemImage: "tablecells").tag(StatementOutcome.ViewMode.grid)
                    Label("Chart", systemImage: "chart.bar.xaxis").tag(StatementOutcome.ViewMode.chart)
                    if outcome.plan != nil {
                        Label("Plan", systemImage: "list.bullet.indent").tag(StatementOutcome.ViewMode.plan)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Show as grid, chart or plan")
                Menu {
                    Section("Copy") {
                        ForEach(ExportFormat.allCases) { format in Button(format.displayName) { model.copy(rowSet, as: format) } }
                    }
                    Section("Export to file") {
                        ForEach(ExportFormat.allCases) { format in Button("\(format.displayName)…") { model.export(rowSet, as: format) } }
                    }
                    if outcome.kind == .query {
                        Divider()
                        Button("Export All Rows with COPY (CSV)…") { model.exportWithCopy(outcome.sql) }
                    }
                    Divider()
                    Button("Copy SQL") { Pasteboard.copy(outcome.executedSQL) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy or export the result")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if outcome.isRunning {
            VStack(spacing: 10) {
                ProgressView()
                Text(outcome.sql).font(Theme.monospacedSmall).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal, 40)
            }
        } else if let error = outcome.errorMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StatementErrorView(message: error, outcome: outcome, model: model)
                    if let fields = outcome.error?.fields {
                        KeyValueList(items: Self.errorDetails(fields), monospacedValues: false)
                    }
                    NoticeList(notices: outcome.notices)
                    Text(outcome.executedSQL)
                        .font(Theme.monospacedSmall)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        } else if outcome.viewMode == .plan, let plan = outcome.plan {
            PlanView(plan: plan)
        } else if let rowSet = outcome.rowSet {
            VStack(spacing: 0) {
                switch outcome.viewMode {
                case .grid, .plan:
                    ResultGrid(resultID: outcome.id, columns: rowSet.columns, rows: rowSet.rows,
                               insertTableName: model.sourceTableName(rowSet) ?? "exported",
                               onInspect: { model.inspected = $0 })
                case .chart:
                    if outcome.chart == nil, let state = ChartState(result: rowSet) {
                        Color.clear.onAppear { outcome.chart = state }
                    } else if let chart = outcome.chart {
                        ChartPanel(chart: chart)
                    } else {
                        ContentUnavailableView("Nothing to Chart", systemImage: "chart.bar.xaxis",
                                               description: Text("Charts need at least one numeric column."))
                    }
                }
                if !outcome.notices.isEmpty || !outcome.notifications.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            NoticeList(notices: outcome.notices)
                            ForEach(Array(outcome.notifications.enumerated()), id: \.offset) { _, note in
                                Label("NOTIFY \(note.channel): \(note.payload) (pid \(note.processID))", systemImage: "bell")
                                    .font(.caption)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                    Text(outcome.results.last?.commandTag?.raw ?? "Statement executed successfully").font(.headline)
                    if let error = outcome.planError { Text(error).font(.caption).foregroundStyle(.red) }
                    NoticeList(notices: outcome.notices).frame(maxWidth: 640)
                    ForEach(Array(outcome.notifications.enumerated()), id: \.offset) { _, note in
                        Label("NOTIFY \(note.channel): \(note.payload) (pid \(note.processID))", systemImage: "bell").font(.caption)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Fields not in the error's header. The statement position (`P`) is relative to the text sent, so the editor
    /// position in the header replaces it.
    static func errorDetails(_ fields: ServerMessageFields) -> [(String, String)] {
        var items: [(String, String)] = []
        if let detail = fields.detail { items.append(("Detail", SQLServerError.shortenedForDisplay(detail))) }
        if let context = fields.whereContext { items.append(("Context", SQLServerError.shortenedForDisplay(context))) }
        if let query = fields.internalQuery {
            items.append(("Internal query", SQLServerError.shortenedForDisplay(query) + (fields.internalPosition.map { " (at character \($0))" } ?? "")))
        }
        let object = [fields.schemaName, fields.tableName, fields.columnName].compactMap { $0 }.joined(separator: ".")
        if !object.isEmpty { items.append(("Object", object)) }
        if let constraint = fields.constraintName { items.append(("Constraint", constraint)) }
        return items
    }
}

/// Server notices (RAISE NOTICE, warnings) of a statement.
struct NoticeList: View {
    let notices: [ServerMessageFields]

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Badge(text: notice.severity, color: notice.severity.hasPrefix("WARN") ? .orange : .blue)
                        Text(notice.message + (notice.detail.map { " — \($0)" } ?? "")).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - History

private struct HistoryPanel: View {
    let model: SQLTabModel
    @State private var search = ""
    @State private var entries: [QueryHistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $search).textFieldStyle(.plain)
            }
            .padding(10)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("Executed statements appear here."))
                    .frame(height: 260)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.sql)
                            .font(Theme.monospacedSmall)
                            .lineLimit(3)
                        HStack(spacing: 8) {
                            Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(entry.succeeded ? .green : .red)
                            Text(entry.executedAt, style: .relative)
                            Text(Format.duration(milliseconds: entry.durationMilliseconds))
                            if let rows = entry.rowCount { Text("\(rows.formatted()) rows") }
                            if let database = entry.database { Text(database).foregroundStyle(.tertiary) }
                            Spacer()
                            Button("Open") {
                                model.text = entry.sql
                                model.showHistory = false
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        Button("Copy SQL") { Pasteboard.copy(entry.sql) }
                        Button("Open in New Tab") { model.workspace.openSQL(text: entry.sql, database: entry.database) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 520, height: 420)
        .task(id: search) {
            try? await Task.sleep(for: .milliseconds(120))
            entries = await model.workspace.history.search(search)
        }
    }
}
