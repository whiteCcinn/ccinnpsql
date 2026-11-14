import Foundation
import os
import PostgresWire

/// A dedicated connection that receives NOTIFY messages as they arrive (LISTEN/NOTIFY panel).
///
/// A background loop owns the read side of the socket; LISTEN/UNLISTEN/NOTIFY commands are written by
/// callers and completed in order by the loop when their ReadyForQuery arrives.
public final class PostgresListener: Sendable {
    public let notifications: AsyncStream<NotificationMessage>
    private let continuation: AsyncStream<NotificationMessage>.Continuation
    private let transport: any ByteTransport
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let loop = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    private struct State {
        var pending: [CheckedContinuation<Void, any Error>] = []
        var channels: Set<String> = []
        var closed = false
        var failure: PostgresError?
    }

    /// Opens a listener connection to `database` (default database when nil).
    public static func open(client: PostgresClient, database: String? = nil) async throws -> PostgresListener {
        guard client.serverInfo.keepsSessionState else {
            throw PostgresError(.unsupported, "LISTEN needs session state, which this connection's transaction pooler does not keep. Connect directly to PostgreSQL to listen for notifications.")
        }
        let configuration = database.map { client.effectiveConfiguration.with(database: $0) } ?? client.effectiveConfiguration
        let mode = configuration.sslMode
        let tls = configuration.tlsConfiguration(mode: mode == .prefer && client.serverInfo.tlsDescription == nil ? .disable : mode)
        let transport = try await client.transportFactory(configuration.endpoint,
                                                          TransportOptions(connectTimeout: configuration.connectTimeout, tls: tls))
        let channel: MessageChannel
        do {
            channel = try await Deadline.run(seconds: max(1, configuration.connectTimeout), timeoutError: {
                PostgresError(.timeout, "The listener connection did not start in time")
            }) {
                var local = MessageChannel(transport: transport, maxMessageSize: 64 * 1024 * 1024)
                _ = try await Startup.perform(channel: &local, configuration: configuration)
                return local
            }
        } catch {
            transport.close()
            throw error
        }
        let listener = PostgresListener(transport: transport)
        listener.start(channel: channel)
        return listener
    }

    private init(transport: any ByteTransport) {
        self.transport = transport
        (notifications, continuation) = AsyncStream.makeStream(of: NotificationMessage.self, bufferingPolicy: .bufferingNewest(10_000))
    }

    public var channels: [String] { state.withLock { $0.channels.sorted() } }

    public func listen(_ channelName: String) async throws {
        try await command("LISTEN " + SQLText.quoteIdentifier(channelName))
        _ = state.withLock { $0.channels.insert(channelName) }
    }

    public func unlisten(_ channelName: String) async throws {
        try await command("UNLISTEN " + SQLText.quoteIdentifier(channelName))
        _ = state.withLock { $0.channels.remove(channelName) }
    }

    /// Sends a notification with `pg_notify` (channel and payload as literals).
    public func notify(_ channelName: String, payload: String) async throws {
        try await command("SELECT pg_notify(\(SQLText.literal(channelName)), \(SQLText.literal(payload)))")
    }

    public func close() {
        let pending = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.closed = true
            defer { state.pending.removeAll() }
            return state.pending
        }
        for waiter in pending { waiter.resume(throwing: PostgresError(.connectionClosed, "The listener was closed")) }
        let transport = transport
        Task {
            try? await transport.send(FrontendMessage.terminate)
            transport.close()
        }
        continuation.finish()
        loop.withLock { $0?.cancel() }
    }

    deinit {
        transport.close()
        continuation.finish()
    }

    // MARK: Plumbing

    private func command(_ sql: String) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            let rejection = state.withLock { state -> PostgresError? in
                if state.closed { return state.failure ?? PostgresError(.connectionClosed, "The listener is closed") }
                state.pending.append(waiter)
                return nil
            }
            if let rejection {
                waiter.resume(throwing: rejection)
                return
            }
            let transport = transport
            Task {
                do {
                    try await transport.send(FrontendMessage.query(sql))
                } catch {
                    transport.close() // the read loop then fails every pending command
                }
            }
        }
    }

    private func start(channel: MessageChannel) {
        let continuation = continuation
        let task = Task.detached { [weak self] in
            var channel = channel
            var commandError: ServerMessageFields?
            while true {
                do {
                    let message = try await channel.read()
                    switch try message.parse() {
                    case let .notification(note):
                        continuation.yield(note)
                    case let .errorResponse(fields):
                        commandError = fields
                    case .readyForQuery:
                        let error = commandError.map(PostgresError.server)
                        commandError = nil
                        self?.completeNext(error)
                    default:
                        continue
                    }
                } catch {
                    self?.fail(PostgresError(.connectionClosed, "The listener connection ended: \(error.localizedDescription)"))
                    return
                }
            }
        }
        loop.withLock { $0 = task }
    }

    private func completeNext(_ error: PostgresError?) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            state.pending.isEmpty ? nil : state.pending.removeFirst()
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }

    private func fail(_ error: PostgresError) {
        let pending = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            state.closed = true
            state.failure = error
            defer { state.pending.removeAll() }
            return state.pending
        }
        for waiter in pending { waiter.resume(throwing: error) }
        continuation.finish()
    }
}
