import Foundation
import PostgresWire

/// How the workbench sends a statement.
public enum ExecutionMode: Sendable, Equatable {
    /// Extended protocol: exactly one statement, error positions relative to it, Execute row count.
    case extended
    /// Simple protocol: a script of several statements in one message, every result returned.
    case simple
}

/// A dedicated connection for one SQL editor (design D7): keeps session state, reconnects lazily replaying the
/// session's settings, runs one statement at a time and cancels the running statement with a CancelRequest.
public actor SQLSession {
    private let client: PostgresClient
    public nonisolated let database: String
    private var connection: PostgresConnection?
    private var settings = SessionSettingsLog()
    /// A run is in progress (connecting or executing).
    public private(set) var isBusy = false
    /// Stop was pressed while the current run had not reached the connection yet (still connecting). The run
    /// then stops before sending its statement instead of ignoring the request.
    private var cancelRequestedBeforeStart = false
    /// Cancels the statement in flight (set while one runs).
    private var cancelStatement: (@Sendable () -> Void)?
    /// The current run's statement has been handed to the connection (Stop then cancels it).
    public var isStatementRunning: Bool { cancelStatement != nil }
    /// Increases with every statement so stale completions can be told apart.
    private var runGeneration: UInt64 = 0
    /// The session lost its connection while a transaction was open (it was rolled back by the server).
    public private(set) var lostTransaction = false

    init(client: PostgresClient, database: String) {
        self.client = client
        self.database = database
    }

    public var transactionStatus: TransactionStatus {
        get async { await connection?.transactionStatus ?? .idle }
    }

    /// Backend pid of the session's connection (BackendKeyData).
    public var backendProcessID: Int32? { connection?.backendKey?.processID }

    /// Runs one statement (extended) or a script (simple) and returns everything it produced.
    public func run(_ sql: String, mode: ExecutionMode = .extended, limits: RowLimits = RowLimits()) async throws -> QueryResult {
        // One statement at a time; a rejected second run must not touch the running one's state.
        guard !isBusy else { throw PostgresError(.busy, "This editor is already running a statement") }
        isBusy = true
        cancelRequestedBeforeStart = false
        defer { isBusy = false }
        let connection = try await ensureConnection()
        runGeneration &+= 1
        lostTransaction = false
        settings.align(with: await connection.transactionStatus)
        if cancelRequestedBeforeStart { throw PostgresError.cancelled() }
        do {
            let result: QueryResult = try await runOwned {
                switch mode {
                case .extended: try await connection.extendedQuery(sql, limits: limits)
                case .simple: try await connection.simpleQuery(sql, limits: limits)
                }
            }
            if client.serverInfo.keepsSessionState {
                // Statement by statement: a script's settings stick only as far as its transactions committed.
                let statements = mode == .simple ? SimpleStatementSplitter.split(sql) : [sql]
                settings.recordBatch(statements, completed: mode == .simple ? result.completedStatements : statements.count,
                                     failed: result.cancelledAtRowLimit, finalStatus: result.transactionStatus)
            }
            return try await client.resolvingTypeNames(result, database: database)
        } catch let error as PostgresError {
            if await connection.isBroken {
                if self.connection === connection { self.connection = nil }
                settings.discardPending()
            } else if client.serverInfo.keepsSessionState {
                let statements = mode == .simple ? SimpleStatementSplitter.split(sql) : [sql]
                settings.recordBatch(statements, completed: mode == .simple ? error.completedStatements : 0, failed: true,
                                     finalStatus: await connection.transactionStatus)
            }
            throw error
        }
    }

    /// Streams `COPY … TO STDOUT` on this session's connection, so the export sees the session's search_path,
    /// role, temporary tables and open transaction exactly like the query it exports.
    public func copyOut(_ sql: String, sink: @escaping @Sendable ([UInt8]) async throws -> Void) async throws -> CommandTag? {
        guard !isBusy else { throw PostgresError(.busy, "This editor is already running a statement") }
        isBusy = true
        cancelRequestedBeforeStart = false
        defer { isBusy = false }
        let connection = try await ensureConnection()
        runGeneration &+= 1
        if cancelRequestedBeforeStart { throw PostgresError.cancelled() }
        do {
            return try await runOwned { try await connection.copyOut(sql, sink: sink) }
        } catch {
            if await connection.isBroken {
                if self.connection === connection { self.connection = nil }
                settings.discardPending()
            } else if await connection.transactionStatus == .failedTransaction {
                settings.recordBatch([sql], completed: 0, failed: true, finalStatus: .failedTransaction)
            }
            throw error
        }
    }

    /// Stops the current run: before it reaches the server it is not sent at all; once handed to the
    /// connection its task is cancelled, which sends a CancelRequest as soon as the statement is registered
    /// (task cancellation is sticky, so there is no window in which Stop is lost). Never touches a later run.
    public func cancel() {
        guard isBusy else { return }
        if let cancelStatement {
            cancelStatement()
        } else {
            cancelRequestedBeforeStart = true
        }
    }

    /// Runs the statement in a task the session owns, so `cancel()` can stop it; the caller's cancellation
    /// is forwarded too.
    private func runOwned<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        cancelStatement = { task.cancel() }
        defer { cancelStatement = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func close() async {
        await connection?.close()
        connection = nil
    }

    /// Settings a reconnect would replay (for tests and the UI).
    public var replayedSettings: [String] { settings.replayStatements }

    private func ensureConnection() async throws -> PostgresConnection {
        if let connection {
            if await !connection.isBroken { return connection }
            let status = await connection.transactionStatus
            if status != .idle { lostTransaction = true }
            self.connection = nil
        }
        let fresh = try await client.makeConnection(database: database)
        // Restore session settings made before the reconnect (best effort).
        for statement in settings.replayStatements {
            _ = try? await fresh.simpleQuery(statement, limits: .metadata)
        }
        connection = fresh
        return fresh
    }
}

/// Splits a script on semicolons outside quotes, dollar quotes and comments (enough to find SET statements).
enum SimpleStatementSplitter {
    static func split(_ script: String) -> [String] {
        var statements: [String] = []
        var current = ""
        let scalars = Array(script.unicodeScalars)
        var index = 0
        func peek(_ offset: Int) -> Unicode.Scalar? { index + offset < scalars.count ? scalars[index + offset] : nil }
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "'", index > 0, scalars[index - 1] == "E" || scalars[index - 1] == "e",
               index < 2 || !(scalars[index - 2].properties.isAlphabetic || scalars[index - 2] == "_" || ("0"..."9").contains(scalars[index - 2])) {
                // E'…' escape string: a backslash escapes the next character, including a quote.
                current.unicodeScalars.append(scalar)
                index += 1
                while index < scalars.count {
                    current.unicodeScalars.append(scalars[index])
                    if scalars[index] == "\\", index + 1 < scalars.count {
                        current.unicodeScalars.append(scalars[index + 1])
                        index += 2
                        continue
                    }
                    if scalars[index] == "'" {
                        if peek(1) == "'" {
                            current.unicodeScalars.append(scalars[index + 1])
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            if scalar == "'" || scalar == "\"" {
                let quote = scalar
                current.unicodeScalars.append(scalar)
                index += 1
                while index < scalars.count {
                    current.unicodeScalars.append(scalars[index])
                    if scalars[index] == quote {
                        if peek(1) == quote {
                            current.unicodeScalars.append(scalars[index + 1])
                            index += 2
                            continue
                        }
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            if scalar == "-", peek(1) == "-" {
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                continue
            }
            if scalar == "/", peek(1) == "*" {
                var depth = 0
                while index < scalars.count {
                    if scalars[index] == "/", peek(1) == "*" { depth += 1; index += 2; continue }
                    if scalars[index] == "*", peek(1) == "/" { depth -= 1; index += 2; if depth == 0 { break }; continue }
                    index += 1
                }
                continue
            }
            if scalar == "$" {
                // Dollar quote: $tag$ … $tag$
                var end = index + 1
                while end < scalars.count, scalars[end] != "$", scalars[end].properties.isAlphabetic || scalars[end] == "_" || ("0"..."9").contains(scalars[end]) {
                    end += 1
                }
                if end < scalars.count, scalars[end] == "$", !(index + 1 < scalars.count && ("0"..."9").contains(scalars[index + 1])) {
                    let tag = Array(scalars[index...end])
                    var search = end + 1
                    var closed = scalars.count
                    while search + tag.count <= scalars.count {
                        if Array(scalars[search..<(search + tag.count)]) == tag { closed = search + tag.count; break }
                        search += 1
                    }
                    for offset in index..<min(closed, scalars.count) { current.unicodeScalars.append(scalars[offset]) }
                    index = closed
                    continue
                }
            }
            if scalar == ";" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { statements.append(trimmed) }
                current = ""
                index += 1
                continue
            }
            current.unicodeScalars.append(scalar)
            index += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { statements.append(trimmed) }
        return statements
    }
}
