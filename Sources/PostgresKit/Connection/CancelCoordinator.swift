import Foundation
import os
import PostgresWire

/// Identifies a backend for CancelRequest.
public struct BackendKey: Sendable, Equatable {
    public let processID: Int32
    public let secretKey: [UInt8]

    public init(processID: Int32, secretKey: [UInt8]) {
        self.processID = processID
        self.secretKey = secretKey
    }
}

/// Why a running statement is being cancelled.
public enum CancelReason: Sendable, Equatable {
    /// The caller's task was cancelled (user, timeout, MCP client).
    case task
    /// The row limit was reached on a protocol path that cannot stop the server otherwise.
    case rowLimit
}

/// Race-free cancellation for one connection (design D6).
///
/// - A cancel is sent only while the given run generation is still executing (never for an idle connection
///   or a newer statement).
/// - The next run waits until an in-flight CancelRequest has been delivered (the postmaster closes the cancel
///   socket after signalling the backend), so a late cancel cannot interrupt the following statement.
/// - If the statement keeps running for `graceSeconds` after the cancel, the socket is closed.
final class CancelCoordinator: Sendable {
    private struct State {
        var generation: UInt64 = 0
        var isRunning = false
        var cancelledGeneration: UInt64?
        var reason: CancelReason?
        var pendingDelivery: Task<Void, Never>?
    }

    typealias Sender = @Sendable () async -> Void

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sender: Sender
    private let forceClose: @Sendable () -> Void
    let graceSeconds: Double

    init(graceSeconds: Double = 5, sender: @escaping Sender, forceClose: @escaping @Sendable () -> Void) {
        self.graceSeconds = graceSeconds.isFinite ? min(max(0.1, graceSeconds), 120) : 5
        self.sender = sender
        self.forceClose = forceClose
    }

    /// Waits for a previous cancel to be delivered (bounded by the sender's own timeout). Returns early when the
    /// waiting task is cancelled, so a caller is never stuck behind someone else's cancel.
    func waitForPendingDelivery() async {
        guard let pending = state.withLock({ $0.pendingDelivery }) else { return }
        let gate = OneShotGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate.arm(continuation)
                Task.detached {
                    await pending.value
                    gate.open()
                }
            }
        } onCancel: {
            gate.open()
        }
    }

    func begin() -> UInt64 {
        state.withLock { state in
            state.generation &+= 1
            state.isRunning = true
            state.cancelledGeneration = nil
            state.reason = nil
            return state.generation
        }
    }

    func end(_ generation: UInt64) {
        state.withLock { state in
            if state.generation == generation { state.isRunning = false }
        }
    }

    /// The reason `generation` was cancelled, if it was.
    func cancellation(of generation: UInt64) -> CancelReason? {
        state.withLock { $0.cancelledGeneration == generation ? $0.reason : nil }
    }

    var isRunning: Bool { state.withLock { $0.isRunning } }
    var currentGeneration: UInt64 { state.withLock { $0.generation } }

    /// Sends a CancelRequest for `generation` if it is still running and not yet cancelled. Returns whether one was sent.
    @discardableResult
    func cancel(generation: UInt64, reason: CancelReason) -> Bool {
        let shouldSend = state.withLock { state -> Bool in
            guard state.generation == generation, state.isRunning, state.cancelledGeneration != generation else { return false }
            state.cancelledGeneration = generation
            state.reason = reason
            return true
        }
        guard shouldSend else { return false }
        let sender = sender
        let delivery = Task.detached { await sender() }
        state.withLock { $0.pendingDelivery = delivery }
        let grace = graceSeconds
        let forceClose = forceClose
        let state = state
        Task.detached {
            await delivery.value
            try? await Task.sleep(for: .milliseconds(Int(grace * 1000)))
            let stillRunning = state.withLock { $0.generation == generation && $0.isRunning }
            if stillRunning { forceClose() }
        }
        return true
    }
}

/// A continuation that is resumed exactly once, by whichever of several events comes first.
final class OneShotGate: Sendable {
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, opened: Bool)>(initialState: (nil, false))

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.opened { return true }
            state.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func open() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.opened = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}

/// Sends CancelRequest messages on short-lived connections to the server that runs the session.
enum CancelRequestSender {
    /// Connects to `endpoint` (the resolved address of the session), optionally negotiating TLS first,
    /// sends the CancelRequest and waits until the server closes the socket (delivery), bounded by `timeout`.
    static func send(key: BackendKey, endpoint: Endpoint, tls: TLSConfiguration?, transportFactory: @escaping TransportFactory,
                     timeout: Double = 5) async {
        let message = FrontendMessage.cancelRequest(processID: key.processID, secretKey: key.secretKey)
        _ = try? await Deadline.run(seconds: timeout, timeoutError: { PostgresError(.timeout, "cancel request timed out") }) {
            var transport: (any ByteTransport)?
            if let tls {
                transport = try? await transportFactory(endpoint, TransportOptions(connectTimeout: timeout, tls: tls))
            }
            if transport == nil {
                transport = try await transportFactory(endpoint, TransportOptions(connectTimeout: timeout, tls: nil))
            }
            guard let transport else { return }
            defer { transport.close() }
            try await withTaskCancellationHandler {
                try await transport.send(message)
                // The postmaster signals the backend and then closes the connection.
                while true { _ = try await transport.receive() }
            } onCancel: {
                transport.close()
            }
        }
    }
}
