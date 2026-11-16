import Foundation
import os
@testable import PostgresKit
import PostgresWire

/// Backend message builders for fakes.
enum Wire {
    static func message(_ type: Character, _ body: [UInt8] = []) -> [UInt8] {
        var writer = ByteWriter()
        writer.writeUInt8(type.asciiValue ?? 0)
        writer.writeInt32(Int32(body.count + 4))
        writer.writeBytes(body)
        return writer.bytes
    }

    static func cstring(_ text: String) -> [UInt8] { Array(text.utf8) + [0] }
    static func int16(_ value: Int16) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    static func int32(_ value: Int32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    /// Concatenates byte arrays. Long `+` chains are too slow for older type checkers (Swift 6.2 in CI).
    static func concatBytes(_ parts: [UInt8]...) -> [UInt8] { parts.flatMap { $0 } }

    static func authOK() -> [UInt8] { message("R", int32(0)) }
    static func ready(_ status: Character = "I") -> [UInt8] { message("Z", [status.asciiValue ?? 0x49]) }
    static func keyData(pid: Int32, key: Int32) -> [UInt8] { message("K", int32(pid) + int32(key)) }
    static func parameter(_ name: String, _ value: String) -> [UInt8] { message("S", cstring(name) + cstring(value)) }
    static func complete(_ tag: String) -> [UInt8] { message("C", cstring(tag)) }

    static func rowDescription(_ names: [String], type: Int32 = 25) -> [UInt8] {
        var body = int16(Int16(names.count))
        for name in names { body += concatBytes(cstring(name), int32(0), int16(0), int32(type), int16(-1), int32(-1), int16(0)) }
        return message("T", body)
    }

    static func dataRow(_ values: [String?]) -> [UInt8] {
        var body = int16(Int16(values.count))
        for value in values {
            if let value { body += int32(Int32(value.utf8.count)) + Array(value.utf8) } else { body += int32(-1) }
        }
        return message("D", body)
    }

    static func error(_ code: String, _ text: String, severity: String = "ERROR") -> [UInt8] {
        // Built field by field: one long `+` chain is too slow for older type checkers (Swift 6.2 in CI).
        var body: [UInt8] = []
        let fields: [(UInt8, String)] = [(UInt8(ascii: "S"), severity), (UInt8(ascii: "V"), severity),
                                         (UInt8(ascii: "C"), code), (UInt8(ascii: "M"), text)]
        for (field, value) in fields {
            body.append(field)
            body.append(contentsOf: cstring(value))
        }
        body.append(0)
        return message("E", body)
    }

    static func rows(_ names: [String], _ values: [[String?]], tag: String? = nil) -> [UInt8] {
        concatBytes(rowDescription(names), values.flatMap(dataRow), complete(tag ?? "SELECT \(values.count)"))
    }
}

/// A frontend message as the fake server sees it.
struct FrontendPacket: Sendable {
    let type: UInt8?
    let body: [UInt8]

    var query: String? {
        guard let type, type == UInt8(ascii: "Q") || type == UInt8(ascii: "P") else { return nil }
        var reader = ByteReader(body)
        if type == UInt8(ascii: "P") { _ = try? reader.readCString() }
        return try? reader.readCString()
    }
}

/// In-memory PostgreSQL server speaking enough protocol for connection tests.
final class FakePostgresServer: ByteTransport, @unchecked Sendable {
    enum Auth: Sendable {
        case trust
        case cleartext
        /// Sends AuthenticationSASL, answers the client-first with a SASLContinue, then (maliciously) AuthenticationOk.
        case scramWithoutFinal
        case reject
    }

    enum Reply: Sendable {
        case bytes([UInt8])
        /// Sent as is (the reply must include its own ReadyForQuery).
        case raw([UInt8])
        /// Never answers until cancelled (then 57014) or closed.
        case hang
        /// Answers after a delay unless a cancel arrives first (then 57014). A cancel arriving while the server is
        /// idle is ignored, as PostgreSQL does.
        case delayed([UInt8], seconds: Double)
        /// Sends the bytes (e.g. some rows), then keeps the statement running until cancelled (then 57014).
        case partialThenHang([UInt8])
    }

    private struct State {
        var outbox: [UInt8] = []
        var receiver: CheckedContinuation<[UInt8], any Error>?
        var closed = false
        var inbox: [UInt8] = []
        var startupDone = false
        var packets: [FrontendPacket] = []
        var hanging = false
        var cancels = 0
        var extendedPending = false
        var cancelArrivals: [ContinuousClock.Instant] = []
        var queryArrivals: [ContinuousClock.Instant] = []
        var pendingGeneration = 0
        var idleCancels = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let auth: Auth
    let pid: Int32
    let ignoresCancel: Bool
    let handler: @Sendable (String) -> Reply

    init(pid: Int32 = 4242, auth: Auth = .trust, ignoresCancel: Bool = false,
         handler: @escaping @Sendable (String) -> Reply = { _ in .bytes(Wire.complete("SELECT 0")) }) {
        self.pid = pid
        self.auth = auth
        self.ignoresCancel = ignoresCancel
        self.handler = handler
    }

    var packets: [FrontendPacket] { state.withLockUnchecked { $0.packets } }
    var queries: [String] { packets.compactMap(\.query) }
    var cancelCount: Int { state.withLockUnchecked { $0.cancels } }
    var isClosed: Bool { state.withLockUnchecked { $0.closed } }
    var isHanging: Bool { state.withLockUnchecked { $0.hanging } }
    var cancelArrivals: [ContinuousClock.Instant] { state.withLockUnchecked { $0.cancelArrivals } }
    var queryArrivals: [ContinuousClock.Instant] { state.withLockUnchecked { $0.queryArrivals } }
    /// Cancels that arrived while nothing was running (ignored).
    var idleCancels: Int { state.withLockUnchecked { $0.idleCancels } }

    var remoteEndpoint: Endpoint? { Endpoint(host: "10.0.0.7", port: 5432) }

    // MARK: ByteTransport

    func send(_ bytes: [UInt8]) async throws {
        let packets = try state.withLockUnchecked { state -> [FrontendPacket] in
            guard !state.closed else { throw PostgresError(.connectionClosed, "closed") }
            state.inbox += bytes
            var parsed: [FrontendPacket] = []
            while true {
                if !state.startupDone {
                    guard state.inbox.count >= 4 else { break }
                    let length = Int(UInt32(state.inbox[0]) << 24 | UInt32(state.inbox[1]) << 16 | UInt32(state.inbox[2]) << 8 | UInt32(state.inbox[3]))
                    guard state.inbox.count >= length else { break }
                    parsed.append(FrontendPacket(type: nil, body: Array(state.inbox[4..<length])))
                    state.inbox.removeFirst(length)
                    state.startupDone = true
                } else {
                    guard state.inbox.count >= 5 else { break }
                    let length = Int(UInt32(state.inbox[1]) << 24 | UInt32(state.inbox[2]) << 16 | UInt32(state.inbox[3]) << 8 | UInt32(state.inbox[4]))
                    guard state.inbox.count >= 1 + length else { break }
                    parsed.append(FrontendPacket(type: state.inbox[0], body: Array(state.inbox[5..<(1 + length)])))
                    state.inbox.removeFirst(1 + length)
                }
            }
            state.packets += parsed
            return parsed
        }
        for packet in packets { handle(packet) }
    }

    func receive() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            state.withLockUnchecked { state in
                if !state.outbox.isEmpty {
                    let bytes = state.outbox
                    state.outbox.removeAll()
                    continuation.resume(returning: bytes)
                } else if state.closed {
                    continuation.resume(throwing: PostgresError(.connectionClosed, "closed"))
                } else {
                    state.receiver = continuation
                }
            }
        }
    }

    func close() {
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            state.closed = true
            defer { state.receiver = nil }
            return state.receiver
        }
        receiver?.resume(throwing: PostgresError(.connectionClosed, "closed"))
    }

    /// A CancelRequest arrived for this backend: a hanging statement fails with 57014.
    func cancel() {
        let wasHanging = state.withLockUnchecked { state -> Bool in
            state.cancels += 1
            state.cancelArrivals.append(ContinuousClock.now)
            guard !ignoresCancel else { return false }
            if !state.hanging { state.idleCancels += 1 }
            defer {
                state.hanging = false
                state.pendingGeneration += 1 // a delayed answer must not follow the cancel error
            }
            return state.hanging
        }
        if wasHanging { enqueue(Wire.error("57014", "canceling statement due to user request") + Wire.ready()) }
    }

    // MARK: Protocol

    private func handle(_ packet: FrontendPacket) {
        guard let type = packet.type else { return startup() }
        switch type {
        case UInt8(ascii: "p"):
            switch auth {
            case .scramWithoutFinal:
                let first = String(decoding: packet.body, as: UTF8.self)
                if first.contains("SCRAM-SHA-256"), let range = first.range(of: "r=") {
                    let nonce = first[range.upperBound...].prefix { $0 != "\0" && $0 != "," }
                    enqueue(Wire.message("R", Wire.int32(11) + Array("r=\(nonce)server,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096".utf8)))
                } else {
                    // Client-final received: skip SASLFinal and pretend success.
                    enqueue(Wire.authOK() + Wire.ready())
                }
            default:
                enqueue(Wire.concatBytes(Wire.authOK(), Wire.keyData(pid: pid, key: 99), Wire.ready()))
            }
        case UInt8(ascii: "Q"):
            respond(to: packet.query ?? "", extended: false)
        case UInt8(ascii: "P"):
            state.withLockUnchecked { $0.extendedPending = true }
            respond(to: packet.query ?? "", extended: true)
        case UInt8(ascii: "X"):
            close()
        default:
            break // Bind/Describe/Execute/Sync are implied by Parse in this fake
        }
    }

    private func startup() {
        switch auth {
        case .trust:
            enqueue(Wire.concatBytes(Wire.authOK(), Wire.parameter("server_version", "17.2"), Wire.parameter("TimeZone", "UTC"),
                                     Wire.keyData(pid: pid, key: 99), Wire.ready()))
        case .cleartext:
            enqueue(Wire.message("R", Wire.int32(3)))
        case .scramWithoutFinal:
            enqueue(Wire.message("R", Wire.concatBytes(Wire.int32(10), Wire.cstring("SCRAM-SHA-256"), [0])))
        case .reject:
            enqueue(Wire.error("28P01", "password authentication failed for user \"x\"", severity: "FATAL"))
        }
    }

    private func respond(to query: String, extended: Bool) {
        state.withLockUnchecked { $0.queryArrivals.append(ContinuousClock.now) }
        switch handler(query) {
        case let .bytes(bytes):
            let prefix: [UInt8] = extended ? Wire.concatBytes(Wire.message("1"), Wire.message("2")) : []
            enqueue(Wire.concatBytes(prefix, bytes, Wire.ready()))
        case let .raw(bytes):
            let prefix: [UInt8] = extended ? Wire.concatBytes(Wire.message("1"), Wire.message("2")) : []
            enqueue(prefix + bytes)
        case .hang:
            state.withLockUnchecked { $0.hanging = true }
            if extended { enqueue(Wire.message("1") + Wire.message("2")) }
        case let .partialThenHang(bytes):
            state.withLockUnchecked { $0.hanging = true }
            let prefix: [UInt8] = extended ? Wire.concatBytes(Wire.message("1"), Wire.message("2")) : []
            enqueue(Wire.concatBytes(prefix, bytes))
        case let .delayed(bytes, seconds):
            let generation = state.withLockUnchecked { state -> Int in
                state.hanging = true
                state.pendingGeneration += 1
                return state.pendingGeneration
            }
            if extended { enqueue(Wire.message("1") + Wire.message("2")) }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                let stillPending = self.state.withLockUnchecked { state -> Bool in
                    guard state.pendingGeneration == generation, state.hanging else { return false }
                    state.hanging = false
                    return true
                }
                if stillPending { self.enqueue(bytes + Wire.ready()) }
            }
        }
    }

    func enqueue(_ bytes: [UInt8]) {
        let receiver = state.withLockUnchecked { state -> CheckedContinuation<[UInt8], any Error>? in
            if let receiver = state.receiver {
                state.receiver = nil
                return receiver
            }
            state.outbox += bytes
            return nil
        }
        receiver?.resume(returning: bytes)
    }
}

/// A transport for the cancel connection: records the CancelRequest, tells the server, then closes.
final class FakeCancelTransport: ByteTransport, @unchecked Sendable {
    private let lookup: @Sendable (Int32) -> FakePostgresServer?
    private let delay: Double
    private let closed = OSAllocatedUnfairLock(initialState: false)
    let received = OSAllocatedUnfairLock<[UInt8]>(initialState: [])

    init(delay: Double = 0, lookup: @escaping @Sendable (Int32) -> FakePostgresServer?) {
        self.lookup = lookup
        self.delay = delay
    }

    func send(_ bytes: [UInt8]) async throws {
        received.withLock { $0 += bytes }
        if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
        var reader = ByteReader(bytes)
        _ = try? reader.readInt32()
        let code = try? reader.readInt32()
        if code == 80_877_102, let pid = try? reader.readInt32() { lookup(pid)?.cancel() }
        closed.withLock { $0 = true }
    }

    func receive() async throws -> [UInt8] {
        // The postmaster closes the cancel connection after signalling.
        for _ in 0..<200 {
            if closed.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PostgresError(.connectionClosed, "closed")
    }

    func close() { closed.withLock { $0 = true } }
}

/// Hands out the main fake for the first connect and cancel transports afterwards.
final class FakeNetwork: @unchecked Sendable {
    let servers: OSAllocatedUnfairLock<[FakePostgresServer]>
    let cancelEndpoints = OSAllocatedUnfairLock<[Endpoint]>(initialState: [])
    private let cancelDelay: Double
    /// Seconds to wait before connection N (0-based, in creation order) is handed out.
    private let connectDelays: [Int: Double]
    private let makeServer: @Sendable (Int) -> FakePostgresServer

    init(cancelDelay: Double = 0, connectDelays: [Int: Double] = [:],
         makeServer: @escaping @Sendable (Int) -> FakePostgresServer = { FakePostgresServer(pid: Int32(100 + $0)) }) {
        self.cancelDelay = cancelDelay
        self.connectDelays = connectDelays
        self.makeServer = makeServer
        servers = OSAllocatedUnfairLock(initialState: [])
    }

    var factory: TransportFactory {
        { [self] endpoint, _ in
            // Cancel connections target the resolved address of the session (10.0.0.7 in this fake).
            if endpoint.host == "10.0.0.7" {
                cancelEndpoints.withLock { $0.append(endpoint) }
                let servers = self.servers
                return FakeCancelTransport(delay: cancelDelay) { pid in servers.withLock { list in list.first { $0.pid == pid } } }
            }
            let (server, index) = servers.withLock { servers -> (FakePostgresServer, Int) in
                let created = makeServer(servers.count)
                servers.append(created)
                return (created, servers.count - 1)
            }
            if let delay = connectDelays[index] { try await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
            return server
        }
    }
}
