import AppKit
import CcinnPsqlKit
import Foundation
import Observation
import PostgresKit
import PostgresWire
import UniformTypeIdentifiers

/// Result of one executed statement (or script).
@MainActor
@Observable
final class StatementOutcome: Identifiable {
    let id = UUID()
    let index: Int
    let sql: String
    let executedSQL: String
    let kind: SQLStatementKind
    let startedAt: Date
    var durationMilliseconds: Double = 0
    var results: [ResultSet] = []
    var notices: [ServerMessageFields] = []
    var notifications: [NotificationMessage] = []
    var error: PostgresError?
    var errorMessage: String?
    var limitApplied: Int?
    var isRunning = true
    var viewMode: ViewMode = .grid
    var chart: ChartState?
    var plan: ExplainPlan?
    var planError: String?
    /// Which result set of a multi-result script is shown.
    var selectedResultIndex: Int?

    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "Grid"
        case chart = "Chart"
        case plan = "Plan"
        var id: String { rawValue }
    }

    init(index: Int, sql: String, executedSQL: String, kind: SQLStatementKind) {
        self.index = index
        self.sql = sql
        self.executedSQL = executedSQL
        self.kind = kind
        startedAt = Date()
    }

    var rowSets: [ResultSet] { results.filter(\.hasRowSet) }

    /// The row set to display.
    var rowSet: ResultSet? {
        let sets = rowSets
        if let selectedResultIndex, sets.indices.contains(selectedResultIndex) { return sets[selectedResultIndex] }
        return sets.last
    }

    var summary: String {
        if isRunning { return "Running…" }
        if errorMessage != nil { return "Failed" }
        if plan != nil { return "Plan" }
        if let rowSet {
            let rows = Format.count(rowSet.rows.count)
            return rowSet.isTruncated ? "\(rows)+ rows" : "\(rows) row\(rowSet.rows.count == 1 ? "" : "s")"
        }
        if let tag = results.last?.commandTag {
            if let count = tag.rowCount, ["INSERT", "UPDATE", "DELETE", "MERGE", "COPY"].contains(tag.verb) {
                return "\(count.formatted()) affected"
            }
            return tag.verb
        }
        return "OK"
    }
}

/// Chart configuration and prepared data for one result.
@MainActor
@Observable
final class ChartState {
    var spec: ChartSpec { didSet { if spec != oldValue { rebuild() } } }
    let roles: [ColumnRole]
    private(set) var data: ChartData = .empty
    private(set) var isPreparing = false
    private let columns: [ColumnDescription]
    private let rows: [[String?]]
    private var buildTask: Task<Void, Never>?

    init?(result: ResultSet) {
        guard result.hasRowSet, !result.rows.isEmpty else { return nil }
        columns = result.columns
        rows = result.rows
        let roles = ChartSuggester.roles(columns: result.columns, rows: result.rows)
        self.roles = roles
        let numeric = roles.indices.first { roles[$0] == .numeric }
        guard let suggested = ChartSuggester.suggest(roles: roles, rows: result.rows)
            ?? numeric.map({ ChartSpec(kind: .bar, xColumn: 0, yColumns: [$0]) }) else { return nil }
        spec = suggested
        rebuild()
    }

    var columnNames: [String] { columns.map(\.name) }
    var numericColumns: [Int] { roles.indices.filter { roles[$0] == .numeric } }

    private func rebuild() {
        buildTask?.cancel()
        isPreparing = true
        let (columns, rows, spec, roles) = (self.columns, self.rows, self.spec, self.roles)
        buildTask = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ChartDataBuilder.build(columns: columns, rows: rows, spec: spec, roles: roles)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.data = data
            self.isPreparing = false
        }
    }
}

/// One SQL editor tab: text, a dedicated session, execution of current/selected/all statements, EXPLAIN, results,
/// notices, transaction state, history and export.
@MainActor
@Observable
final class SQLTabModel {
    let title: String
    var text: String
    var selection = NSRange(location: 0, length: 0)
    private(set) var database: String
    private(set) var transactionStatus: TransactionStatus = .idle
    private(set) var lostTransaction = false
    private(set) var searchPath: [String] = ["public"]
    var outcomes: [StatementOutcome] = []
    var selectedOutcomeID: UUID?
    var isRunning = false
    var runStartedAt: Date?
    var errorRange: NSRange?
    var inspected: InspectedValue?
    var pendingConfirmation: PendingConfirmation?
    var showHistory = false
    var exportProgress: String?

    struct PendingConfirmation: Identifiable {
        let id = UUID()
        let title: String
        let statements: [String]
        let continuation: CheckedContinuation<Bool, Never>
    }

    unowned let workspace: WorkspaceModel
    private var session: SQLSession
    private var runTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    /// Increases with every run so a late completion never overwrites a newer run's state.
    private var runGeneration: UInt64 = 0

    /// Rows kept per result (hard cap) and the default auto-limit for plain SELECTs.
    static let hardRowCap = 100_000
    var autoLimit: Int {
        get { UserDefaults.standard.object(forKey: "autoLimit") as? Int ?? 1000 }
        set { UserDefaults.standard.set(newValue, forKey: "autoLimit") }
    }

    init(title: String, text: String, database: String, workspace: WorkspaceModel) {
        self.title = title
        self.text = text
        self.database = database
        self.workspace = workspace
        session = workspace.client.openSession(database: database)
        selection = NSRange(location: (text as NSString).length, length: 0)
    }

    var selectedOutcome: StatementOutcome? {
        outcomes.first { $0.id == selectedOutcomeID } ?? outcomes.last
    }

    var isConsole: Bool { workspace.isConsole }

    // MARK: Running

    /// Selection if any, otherwise the statement under the cursor.
    func runCurrent() {
        let nsText = text as NSString
        if selection.length > 0, NSMaxRange(selection) <= nsText.length {
            let selected = nsText.substring(with: selection)
            run(SQLStatementSplitter.split(selected).map { Step($0.text, offset: selection.location + $0.range.lowerBound) })
            return
        }
        guard let statement = SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        run([Step(statement.text, offset: statement.range.lowerBound)])
    }

    func runAll() {
        run(SQLStatementSplitter.split(text).map { Step($0.text, offset: $0.range.lowerBound) })
    }

    /// One statement to execute. `hidden` steps (BEGIN/ROLLBACK around EXPLAIN ANALYZE) produce no result tab.
    struct Step {
        let text: String
        let offset: Int?
        var hidden = false
        var plan = false
        /// Characters the app prepended to the user's statement (EXPLAIN …), subtracted from error positions.
        var prefixCharacters = 0

        init(_ text: String, offset: Int? = nil, hidden: Bool = false, plan: Bool = false, prefixCharacters: Int = 0) {
            self.text = text
            self.offset = offset
            self.hidden = hidden
            self.plan = plan
            self.prefixCharacters = prefixCharacters
        }
    }

    /// Sends the whole editor (or the selection) as one simple-protocol script and shows every result set.
    func runScript() {
        let nsText = text as NSString
        let script = selection.length > 0 && NSMaxRange(selection) <= nsText.length ? nsText.substring(with: selection) : text
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        run([Step(script)], mode: .simple)
    }

    /// `EXPLAIN (FORMAT JSON [, ANALYZE, BUFFERS])` of the current statement. ANALYZE of a data-modifying statement runs
    /// inside a transaction that is rolled back.
    func explain(analyze: Bool) {
        guard let statement = selection.length > 0
            ? SQLStatementSplitter.split((text as NSString).substring(with: selection)).first
            : SQLStatementSplitter.statement(at: selection.location, in: text) else { return }
        guard !isRunning else { return }
        var body = statement.text
        var bodyOffset: Int? = statement.range.lowerBound + (selection.length > 0 ? selection.location : 0)
        if SQLStatementKind.of(body) == .explain {
            bodyOffset = nil
            let analysis = SQLLexer(body)
            if let first = analysis.tokens().first(where: { $0.kind != .comment }) {
                body = analysis.text(in: first.range.upperBound..<analysis.units.count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let writes = SQLStatementKind.of(body).isMutation
        let explainSQL = ExplainPlan.statement(for: body, analyze: analyze, buffers: analyze)
        let prefix = explainSQL.unicodeScalars.count - body.unicodeScalars.count
        let explainStep = Step(explainSQL, offset: bodyOffset, plan: true, prefixCharacters: prefix)
        guard analyze, writes else {
            run([explainStep])
            return
        }
        guard transactionStatus == .idle else {
            workspace.showToast("EXPLAIN ANALYZE of a data-modifying statement needs an idle session (finish the open transaction first).", isError: true)
            return
        }
        run([Step("BEGIN", hidden: true), explainStep, Step("ROLLBACK", hidden: true)],
            confirmation: ("EXPLAIN ANALYZE executes the statement. It runs inside a transaction that is rolled back.", [body]), wrapped: true)
    }

    func stop() {
        guard isRunning else { return }
        let session = session
        Task { await session.cancel() }
    }

    /// Runs statements sequentially in this tab's session; stops at the first error.
    private func run(_ statements: [Step], mode: ExecutionMode = .extended,
                     confirmation: (title: String, statements: [String])? = nil, wrapped: Bool = false) {
        guard !isRunning, !statements.isEmpty else { return }
        errorRange = nil
        isRunning = true
        runStartedAt = Date()
        outcomes = []
        runGeneration &+= 1
        let generation = runGeneration
        runTask = Task {
            defer {
                if generation == runGeneration {
                    isRunning = false
                    runStartedAt = nil
                }
            }
            if let confirmation {
                guard await confirm(title: confirmation.title, statements: confirmation.statements) else { return }
            } else {
                let mutations = statements.map(\.text).filter { SQLStatementKind.of($0).isMutation }
                if workspace.profile.confirmMutations, !mutations.isEmpty {
                    guard await confirm(title: "Run statements that change data or schema?", statements: mutations) else { return }
                }
            }
            let effectiveMode: ExecutionMode = isConsole ? .simple : mode
            for (index, step) in statements.enumerated() {
                let succeeded = await execute(step, index: index, mode: effectiveMode, generation: generation)
                if !succeeded || Task.isCancelled || generation != runGeneration {
                    // A failed EXPLAIN ANALYZE inside BEGIN must still be rolled back.
                    if wrapped, transactionStatus != .idle {
                        _ = try? await session.run("ROLLBACK")
                        transactionStatus = await session.transactionStatus
                    }
                    break
                }
            }
        }
    }

    private func confirm(title: String, statements: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingConfirmation = PendingConfirmation(title: title, statements: statements, continuation: continuation)
        }
    }

    func resolveConfirmation(_ confirmed: Bool) {
        pendingConfirmation?.continuation.resume(returning: confirmed)
        pendingConfirmation = nil
    }

    private func execute(_ step: Step, index: Int, mode: ExecutionMode, generation: UInt64) async -> Bool {
        let sql = step.text
        let offset = step.offset
        let plan = step.plan
        let kind = mode == .simple ? SQLStatementKind.other : SQLStatementKind.of(sql)
        var executed = sql
        var limitApplied: Int?
        if mode == .extended, kind == .query, autoLimit > 0, !plan {
            let outcome = AutoLimit.apply(to: sql, limit: autoLimit)
            if outcome.applied {
                executed = outcome.sql
                limitApplied = autoLimit
            }
        }
        let outcome = StatementOutcome(index: index, sql: sql, executedSQL: executed, kind: kind)
        outcome.limitApplied = limitApplied
        // BEGIN/ROLLBACK around EXPLAIN ANALYZE are not shown as separate results.
        let isWrapper = step.hidden
        if !isWrapper {
            outcomes.append(outcome)
            selectedOutcomeID = outcome.id
        }

        let clock = ContinuousClock()
        let started = clock.now
        var historyEntry = QueryHistoryEntry(sql: sql, database: database, durationMilliseconds: 0)
        do {
            let result = try await session.run(executed, mode: mode, limits: RowLimits(maxRows: Self.hardRowCap))
            guard generation == runGeneration else { return false }
            outcome.results = result.results
            outcome.notices = result.notices
            outcome.notifications = result.notifications
            if let rowSet = outcome.rowSet { historyEntry.rowCount = rowSet.rows.count }
            historyEntry.affectedRows = result.results.last?.affectedRows.map { UInt64(max(0, $0)) }
            if plan, let json = outcome.rowSet?.scalar {
                do {
                    outcome.plan = try ExplainPlan.parse(json)
                    outcome.viewMode = .plan
                } catch {
                    outcome.planError = "\(error)"
                }
            }
            noteSearchPath(sql)
            if kind == .definition { refreshSidebar() }
        } catch {
            guard generation == runGeneration else { return false }
            let postgresError = error as? PostgresError
            outcome.error = postgresError
            outcome.notices = postgresError?.notices ?? []
            outcome.errorMessage = describe(error)
            historyEntry.errorMessage = outcome.errorMessage
            if let offset, let position = postgresError?.position.map({ $0 - step.prefixCharacters }), position >= 1 {
                let source = step.prefixCharacters > 0 ? String(String.UnicodeScalarView(sql.unicodeScalars.dropFirst(step.prefixCharacters))) : executed
                if position <= source.unicodeScalars.count, let range = SQLErrorLocator.highlightRange(in: source, position: position) {
                    errorRange = NSRange(location: offset + range.lowerBound, length: range.count)
                }
            }
        }
        transactionStatus = await session.transactionStatus
        lostTransaction = await session.lostTransaction
        let elapsed = clock.now - started
        outcome.durationMilliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        outcome.isRunning = false
        historyEntry.durationMilliseconds = outcome.durationMilliseconds
        if !isWrapper { await workspace.history.append(historyEntry) }
        return outcome.errorMessage == nil
    }

    /// Follows `SET search_path` so completion resolves unqualified names like the server.
    private func noteSearchPath(_ sql: String) {
        guard case let .set(name, statement)? = SessionSettingChange.parse(sql), name == "search_path" else {
            if case .reset(name: "search_path")? = SessionSettingChange.parse(sql) { searchPath = ["public"] }
            return
        }
        var value = Substring(statement)
        if let range = value.range(of: " to ", options: .caseInsensitive) ?? value.range(of: "=") { value = value[range.upperBound...] }
        let schemas = value.split(separator: ",").map { part -> String in
            var name = part.trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) } else if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            } else {
                name = name.lowercased()
            }
            return name == "$user" ? workspace.serverInfo.currentUser : name
        }.filter { !$0.isEmpty }
        if !schemas.isEmpty { searchPath = schemas }
    }

    private func refreshSidebar() {
        guard database == workspace.currentDatabase else { return }
        for schema in workspace.expandedSchemas { workspace.loadSchema(schema, force: true) }
    }

    /// Switches this editor to another database (PostgreSQL sessions are bound to one database).
    func use(database name: String) {
        guard !isRunning, name != database else { return }
        if transactionStatus != .idle {
            workspace.showToast("Finish the open transaction before switching databases.", isError: true)
            return
        }
        let old = session
        Task { await old.close() }
        database = name
        session = workspace.client.openSession(database: name)
        transactionStatus = .idle
        searchPath = ["public"]
    }

    // MARK: Completion

    func completions(text: String, cursor: Int) async -> CompletionResult {
        let (database, searchPath) = (self.database, self.searchPath)
        var result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(database: database, searchPath: searchPath))
        if result.needsMoreSchema {
            await workspace.ensureSchema(columns: result.missingColumns, schemas: result.missingSchemas, database: database)
            result = await Self.complete(text: text, cursor: cursor, schema: workspace.completionSnapshot(database: database, searchPath: searchPath))
        }
        return result
    }

    /// Runs the (pure) completion engine off the main actor.
    private nonisolated static func complete(text: String, cursor: Int, schema: SchemaSnapshot) async -> CompletionResult {
        await Task.detached(priority: .userInitiated) {
            CompletionEngine.complete(text: text, cursor: cursor, schema: schema)
        }.value
    }

    // MARK: Export

    func export(_ result: ResultSet, as format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: " ", with: "_")).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let (columns, rows) = (result.columns, result.rows)
        let table = sourceTableName(result) ?? "exported"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ResultExport.write(format, to: url, columns: columns, rows: rows, table: table)
                }.value
                workspace.showToast("Exported \(Format.count(rows.count)) rows")
            } catch {
                workspace.showToast("Export failed: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func copy(_ result: ResultSet, as format: ExportFormat) {
        let (columns, rows) = (result.columns, result.rows)
        let table = sourceTableName(result) ?? "exported"
        Task {
            let text = await Task.detached(priority: .userInitiated) { ResultExport.render(format, columns: columns, rows: rows, table: table) }.value
            Pasteboard.copy(text)
            workspace.showToast("Copied \(Format.count(rows.count)) rows as \(format.displayName)")
        }
    }

    /// Streams the full result of `sql` with COPY … TO STDOUT (CSV) into a file, without the row limit.
    func exportWithCopy(_ sql: String) {
        guard SQLStatementKind.of(sql) == .query, !isConsole else {
            workspace.showToast("COPY export works for SELECT / WITH / VALUES / TABLE queries.", isError: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: " ", with: "_")).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            workspace.showToast("Could not create \(url.lastPathComponent)", isError: true)
            return
        }
        let copySQL = ResultExport.copyStatement(for: sql)
        let client = workspace.client
        let database = database
        let counter = ByteCounter()
        exportProgress = "Starting COPY…"
        exportTask = Task { [weak self] in
            let progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    let bytes = counter.value
                    self?.exportProgress = "Exported \(Format.bytes(Int64(bytes)))…"
                }
            }
            do {
                let tag = try await client.copyOut(copySQL, database: database) { chunk in
                    try handle.write(contentsOf: Data(chunk))
                    counter.add(chunk.count)
                }
                try? handle.close()
                progressTask.cancel()
                self?.exportProgress = nil
                self?.workspace.showToast("Exported \(tag?.rowCount.map { Format.count(Int64($0)) } ?? "all") rows (\(Format.bytes(Int64(counter.value)))) with COPY")
            } catch {
                try? handle.close()
                progressTask.cancel()
                self?.exportProgress = nil
                self?.workspace.showToast("COPY export failed: \(describe(error))", isError: true)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// The table every column of `result` comes from (for INSERT export), when known from the sidebar's metadata.
    func sourceTableName(_ result: ResultSet) -> String? {
        guard let oid = result.columns.first?.tableOID, oid != 0, result.columns.allSatisfy({ $0.tableOID == oid }),
              database == workspace.currentDatabase else { return nil }
        for schema in workspace.expandedSchemas {
            if let relation = workspace.contents(of: schema)?.relations.first(where: { $0.oid == oid }) { return relation.qualifiedName }
        }
        return nil
    }

    func close() {
        runTask?.cancel()
        exportTask?.cancel()
        if let pendingConfirmation { pendingConfirmation.continuation.resume(returning: false) }
        pendingConfirmation = nil
        let session = session
        Task {
            await session.cancel()
            await session.close()
        }
    }
}

/// Bytes written by a COPY export (updated from the export task, read by the progress loop).
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ count: Int) {
        lock.lock()
        total &+= count
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
