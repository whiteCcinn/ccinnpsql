import Foundation
import os
import PostgresWire

/// Message-level I/O over a transport. A value type so a single owner (startup, then the connection
/// actor) mutates it without locks.
struct MessageChannel: Sendable {
    let transport: any ByteTransport
    var decoder: MessageDecoder

    init(transport: any ByteTransport, maxMessageSize: Int) {
        self.transport = transport
        decoder = MessageDecoder(maxMessageSize: maxMessageSize)
    }

    /// Next backend message. The payload references the decoder's buffer; consume it before the next read.
    mutating func read() async throws -> RawMessage {
        while true {
            if let message = try decoder.next() { return message }
            decoder.append(try await transport.receive())
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await transport.send(bytes)
    }
}

/// One authenticated session to a PostgreSQL server (design D4).
///
/// The actor owns the socket; a command takes the message channel out of the actor for its duration, so
/// overlapping commands fail fast with `.busy` instead of interleaving bytes. Every command reads until
/// ReadyForQuery, so server errors keep the protocol aligned; I/O or framing failures break the connection.
public actor PostgresConnection {
    public nonisolated let endpoint: Endpoint
    public nonisolated let database: String
    public nonisolated let username: String
    /// Process id and secret from BackendKeyData (`nil` when the server sent none, e.g. some poolers).
    public nonisolated let backendKey: BackendKey?
    /// Negotiated TLS version, `nil` when unencrypted.
    public nonisolated let tlsDescription: String?
    /// Resolved address the session is connected to.
    public nonisolated let remoteEndpoint: Endpoint?
    /// ParameterStatus values received during startup (`server_version`, `TimeZone`, …).
    public nonisolated let startupParameters: [String: String]
    nonisolated let canceller: CancelCoordinator
    private nonisolated let transport: any ByteTransport

    private var channel: MessageChannel?
    public private(set) var isBroken = false
    public private(set) var transactionStatus: TransactionStatus = .idle
    /// Current ParameterStatus values (updated as the server reports changes).
    public private(set) var parameters: [String: String]
    private var notificationHandler: (@Sendable (NotificationMessage) -> Void)?

    init(configuration: ConnectionConfiguration, channel: MessageChannel, startup: StartupResult, tls: TLSConfiguration?,
         transportFactory: @escaping TransportFactory) {
        endpoint = configuration.endpoint
        database = configuration.database
        username = configuration.username
        backendKey = startup.backendKey
        transport = channel.transport
        tlsDescription = channel.transport.tlsDescription
        remoteEndpoint = channel.transport.remoteEndpoint
        startupParameters = startup.parameters
        parameters = startup.parameters
        transactionStatus = startup.transactionStatus
        self.channel = channel
        let key = startup.backendKey
        let cancelEndpoint = channel.transport.remoteEndpoint ?? configuration.endpoint
        let transport = channel.transport
        canceller = CancelCoordinator(graceSeconds: configuration.cancelGraceSeconds, sender: {
            guard let key else { return }
            await CancelRequestSender.send(key: key, endpoint: cancelEndpoint, tls: tls, transportFactory: transportFactory)
        }, forceClose: { transport.close() })
    }

    // MARK: Connect

    /// Opens a session: TCP (+ TLS per sslmode), startup, authentication. Fails immediately when the calling
    /// task is already cancelled; the whole setup shares one deadline.
    public static func connect(_ configuration: ConnectionConfiguration,
                               transportFactory: @escaping TransportFactory = Transports.network) async throws -> PostgresConnection {
        if Task.isCancelled { throw PostgresError.cancelled() }
        guard !configuration.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PostgresError(.invalidArgument, "Enter a user name")
        }
        switch configuration.sslMode {
        case .disable:
            return try await attempt(configuration, tls: nil, transportFactory: transportFactory)
        case .prefer:
            do {
                return try await attempt(configuration, tls: configuration.tlsConfiguration(mode: .prefer), transportFactory: transportFactory)
            } catch let error as PostgresError where error.kind == .tls {
                // The server has no TLS (or it failed): `prefer` continues unencrypted, like libpq.
                if Task.isCancelled { throw PostgresError.cancelled() }
                return try await attempt(configuration, tls: nil, transportFactory: transportFactory)
            }
        case .require, .verifyCA, .verifyFull:
            return try await attempt(configuration, tls: configuration.tlsConfiguration(mode: configuration.sslMode), transportFactory: transportFactory)
        }
    }

    private static func attempt(_ configuration: ConnectionConfiguration, tls: TLSConfiguration?,
                                transportFactory: @escaping TransportFactory) async throws -> PostgresConnection {
        let endpoint = configuration.endpoint
        let timeout = max(1, configuration.connectTimeout.isFinite ? configuration.connectTimeout : 10)
        if Task.isCancelled { throw PostgresError.cancelled() }
        let transport = try await transportFactory(endpoint, TransportOptions(connectTimeout: timeout, tls: tls))
        do {
            return try await Deadline.run(seconds: timeout, timeoutError: {
                PostgresError(.timeout, "\(endpoint) did not complete the connection setup within \(Int(timeout))s")
            }) {
                try await withTaskCancellationHandler {
                    var channel = MessageChannel(transport: transport, maxMessageSize: configuration.maxMessageSize)
                    let startup = try await Startup.perform(channel: &channel, configuration: configuration)
                    return PostgresConnection(configuration: configuration, channel: channel, startup: startup, tls: tls,
                                              transportFactory: transportFactory)
                } onCancel: {
                    transport.close()
                }
            }
        } catch {
            transport.close()
            if Task.isCancelled { throw PostgresError.cancelled() }
            throw Self.mapError(error, endpoint: endpoint)
        }
    }

    // MARK: Commands

    /// Simple query protocol: runs `sql` (one or more statements) and returns every result.
    public func simpleQuery(_ sql: String, limits: RowLimits = RowLimits()) async throws -> QueryResult {
        try Self.validate(sql)
        return try await perform { channel, run in
            try await channel.send(FrontendMessage.query(sql))
            var reader = QueryReader(limits: limits, run: run, timeZone: run.timeZone, extended: false)
            return try await reader.readUntilReady(&channel)
        }
    }

    /// Extended query protocol with the unnamed statement and portal: exactly one statement, optional `$n`
    /// parameters, text or binary results. The row limit stops the server with Execute's row count.
    public func extendedQuery(_ sql: String, parameters: [BindValue] = [], parameterTypes: [UInt32] = [],
                              resultFormat: ResultFormat = .text, limits: RowLimits = RowLimits()) async throws -> QueryResult {
        try Self.validate(sql)
        let maxRows = limits.maxRows >= Int(Int32.max) - 1 ? 0 : Int32(limits.maxRows + 1)
        return try await perform { channel, run in
            var reader = QueryReader(limits: limits, run: run, timeZone: run.timeZone, extended: true)
            switch resultFormat {
            case .text:
                try await channel.send(FrontendMessage.parse(statement: "", query: sql, parameterTypes: parameterTypes)
                    + FrontendMessage.bind(portal: "", statement: "", parameters: parameters, resultFormats: [])
                    + FrontendMessage.describe(.portal, name: "")
                    + FrontendMessage.execute(portal: "", maxRows: maxRows)
                    + FrontendMessage.sync)
                return try await reader.readUntilReady(&channel)
            case .binaryWhereSupported:
                try await channel.send(FrontendMessage.parse(statement: "", query: sql, parameterTypes: parameterTypes)
                    + FrontendMessage.describe(.statement, name: "")
                    + FrontendMessage.flush)
                guard let fields = try await reader.readStatementDescription(&channel) else {
                    // The server reported an error and the session is back at ReadyForQuery.
                    return try reader.finish()
                }
                let formats: [FormatCode] = fields.map { PostgresType.supportsBinary($0.typeOID) ? .binary : .text }
                try await channel.send(FrontendMessage.bind(portal: "", statement: "", parameters: parameters, resultFormats: formats)
                    + FrontendMessage.execute(portal: "", maxRows: maxRows)
                    + FrontendMessage.sync)
                reader.expectRows(fields: fields, formats: formats)
                return try await reader.readUntilReady(&channel)
            }
        }
    }

    /// Streams `COPY … TO STDOUT` data to `sink` (one chunk per CopyData message). Returns the command tag.
    public func copyOut(_ sql: String, sink: @escaping @Sendable ([UInt8]) async throws -> Void) async throws -> CommandTag? {
        try Self.validate(sql)
        return try await perform { channel, run in
            try await channel.send(FrontendMessage.query(sql))
            var reader = QueryReader(limits: RowLimits(), run: run, timeZone: run.timeZone, extended: false)
            reader.copySink = sink
            let result = try await reader.readUntilReady(&channel)
            return result.results.last?.commandTag
        }
    }

    /// Receives notifications that arrive during commands (also forwarded in `QueryResult.notifications`).
    public func setNotificationHandler(_ handler: (@Sendable (NotificationMessage) -> Void)?) {
        notificationHandler = handler
    }

    /// Sends Terminate (best effort) and closes the socket.
    public func close() async {
        guard !isBroken else { return }
        isBroken = true
        if let channel = channel.take() {
            try? await channel.send(FrontendMessage.terminate)
        }
        transport.close()
    }

    /// Closes the socket from any context (pool shutdown, last-resort cancellation).
    public nonisolated func forceClose() {
        transport.close()
    }

    /// Sends a CancelRequest for the statement running now, if any (generation-checked).
    public nonisolated func cancelRunningStatement() {
        canceller.cancel(generation: canceller.currentGeneration, reason: .task)
    }

    public var isIdle: Bool { channel != nil && !isBroken }

    // MARK: Plumbing

    struct RunContext: Sendable {
        let generation: UInt64
        let canceller: CancelCoordinator
        let timeZone: String
        let notify: (@Sendable (NotificationMessage) -> Void)?

        func cancelForRowLimit() { canceller.cancel(generation: generation, reason: .rowLimit) }
        var cancellation: CancelReason? { canceller.cancellation(of: generation) }
    }

    private func perform<T: Sendable>(_ operation: (inout MessageChannel, RunContext) async throws -> (T)) async throws -> T {
        guard !isBroken else {
            throw PostgresError(.connectionClosed, "The connection to \(endpoint) is closed")
        }
        guard var channel = channel.take() else {
            throw PostgresError(.busy, "The connection is already running a statement")
        }
        // Late-cancel protection: never start while a previous CancelRequest may still be in flight.
        await canceller.waitForPendingDelivery()
        if Task.isCancelled {
            self.channel = channel
            throw PostgresError.cancelled()
        }
        let canceller = self.canceller
        let generation = canceller.begin()
        let context = RunContext(generation: generation, canceller: canceller, timeZone: parameters["TimeZone"] ?? "UTC",
                                 notify: notificationHandler)
        do {
            let outcome = try await withTaskCancellationHandler {
                try await operation(&channel, context)
            } onCancel: {
                canceller.cancel(generation: generation, reason: .task)
            }
            canceller.end(generation)
            absorb(outcome)
            self.channel = channel
            return outcome
        } catch let failure as QueryFailure {
            // The server reported an error and the session reached ReadyForQuery: still usable.
            canceller.end(generation)
            transactionStatus = failure.transactionStatus
            parameters.merge(failure.parameters) { _, new in new }
            self.channel = channel
            if failure.error.isQueryCanceled, canceller.cancellation(of: generation) == .task || Task.isCancelled {
                var cancelled = PostgresError.cancelled()
                cancelled.notices = failure.notices
                cancelled.completedStatements = failure.completedStatements
                throw cancelled
            }
            var error = failure.error
            error.notices = failure.notices
            error.completedStatements = failure.completedStatements
            throw error
        } catch {
            canceller.end(generation)
            let mapped = Self.mapError(error, endpoint: endpoint)
            markBroken()
            if Task.isCancelled || canceller.cancellation(of: generation) == .task { throw PostgresError.cancelled() }
            throw mapped
        }
    }

    private func absorb<T>(_ outcome: T) {
        if let result = outcome as? QueryResult {
            transactionStatus = result.transactionStatus
            parameters.merge(result.parameterChanges) { _, new in new }
        }
    }

    func applyParameterChanges(_ changes: [String: String], status: TransactionStatus) {
        parameters.merge(changes) { _, new in new }
        transactionStatus = status
    }

    private func markBroken() {
        isBroken = true
        channel = nil
        transport.close()
    }

    static func validate(_ sql: String) throws {
        guard sql.utf8.count < (1 << 30) else { throw PostgresError(.invalidArgument, "The statement is larger than 1 GB") }
    }

    static func mapError(_ error: any Error, endpoint: Endpoint) -> PostgresError {
        switch error {
        case let error as PostgresError: error
        case let failure as QueryFailure: failure.error
        case let wire as PostgresWireError:
            if case let .authentication(message) = wire { PostgresError(.authentication, message) } else {
                PostgresError(.protocolViolation, "\(endpoint): \(wire.description)")
            }
        default: PostgresError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)")
        }
    }
}

/// A server error after which the session is back at ReadyForQuery.
struct QueryFailure: Error, Sendable {
    let error: PostgresError
    let transactionStatus: TransactionStatus
    let parameters: [String: String]
    let notices: [ServerMessageFields]
    var completedStatements = 0
}
