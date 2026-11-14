import Foundation
import Network
import os
import Security

/// `ByteTransport` over Network.framework: plain TCP, TLS after PostgreSQL's SSLRequest on the same
/// socket (design D2), or direct TLS with ALPN `postgresql`.
final class NetworkTransport: ByteTransport, @unchecked Sendable {
    // NWConnection is thread-safe; the connect handshake guards its one-shot continuation with a lock.
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let endpoint: Endpoint
    private let resolved = OSAllocatedUnfairLock<(remote: Endpoint?, tls: String?)>(initialState: (nil, nil))
    /// Why certificate verification failed (set by the verify block), for a precise error message.
    private let verificationFailure: OSAllocatedUnfairLock<PeerCertificateVerifier.Failure?>

    private init(connection: NWConnection, queue: DispatchQueue, endpoint: Endpoint,
                 verificationFailure: OSAllocatedUnfairLock<PeerCertificateVerifier.Failure?>) {
        self.connection = connection
        self.queue = queue
        self.endpoint = endpoint
        self.verificationFailure = verificationFailure
    }

    var remoteEndpoint: Endpoint? { resolved.withLock { $0.remote } }
    var tlsDescription: String? { resolved.withLock { $0.tls } }

    static func connect(to endpoint: Endpoint, options: TransportOptions) async throws -> NetworkTransport {
        if Task.isCancelled { throw PostgresError.cancelled() }
        guard (1...65_535).contains(endpoint.port), let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            throw PostgresError(.invalidArgument, "Invalid port \(endpoint.port)")
        }
        let host = endpoint.host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { throw PostgresError(.invalidArgument, "Enter a host name") }

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = Int(max(1, options.connectTimeout.rounded(.up)))
        let queue = DispatchQueue(label: "ccinnpsql.transport.\(endpoint)", qos: .userInitiated)

        let parameters: NWParameters
        let verificationFailure = OSAllocatedUnfairLock<PeerCertificateVerifier.Failure?>(initialState: nil)
        if let tls = options.tls, tls.mode.usesTLS {
            let tlsOptions = try TLSSetup.options(for: tls, queue: queue, failure: verificationFailure)
            parameters = NWParameters(tls: tlsOptions, tcp: tcp)
            if tls.negotiation == .postgres {
                // Stack: TLS → SSLRequest framer → TCP. The framer negotiates in clear text, then steps aside.
                parameters.defaultProtocolStack.applicationProtocols.append(NWProtocolFramer.Options(definition: SSLRequestFramer.definition))
            }
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }

        let connection = NWConnection(to: .hostPort(host: NWEndpoint.Host(host), port: port), using: parameters)
        let transport = NetworkTransport(connection: connection, queue: queue, endpoint: endpoint, verificationFailure: verificationFailure)
        try await transport.start(timeout: options.connectTimeout, tls: options.tls)
        return transport
    }

    private func start(timeout: Double, tls: TLSConfiguration?) async throws {
        // `done`: the continuation was resumed. `cancelled`: the task was cancelled, possibly before the
        // continuation body ran (a cancelled NWConnection never reports another state, so the body must
        // notice the flag itself instead of waiting for the timeout).
        let once = OSAllocatedUnfairLock(initialState: (done: false, cancelled: false))
        let endpoint = self.endpoint
        let connection = self.connection
        let queue = self.queue
        let resolved = self.resolved
        let verificationFailure = self.verificationFailure

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, PostgresError>) {
                    let first = once.withLock { state -> Bool in
                        defer { state.done = true }
                        return !state.done
                    }
                    guard first else { return }
                    connection.stateUpdateHandler = nil
                    switch result {
                    case .success:
                        resolved.withLock { $0 = (Self.remote(of: connection), Self.tlsVersion(of: connection)) }
                        continuation.resume()
                    case let .failure(error):
                        connection.cancel()
                        continuation.resume(throwing: error)
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: finish(.success(()))
                    case let .failed(error):
                        finish(.failure(Self.describe(error, endpoint: endpoint, tls: tls, verification: verificationFailure.withLock { $0 })))
                    // Network.framework would keep retrying (e.g. connection refused); fail fast instead.
                    case let .waiting(error):
                        finish(.failure(Self.describe(error, endpoint: endpoint, tls: tls, verification: verificationFailure.withLock { $0 })))
                    case .cancelled: finish(.failure(PostgresError(.cancelled, "Connection to \(endpoint) was cancelled")))
                    default: break
                    }
                }
                if once.withLock({ $0.cancelled }) {
                    finish(.failure(PostgresError.cancelled()))
                    return
                }
                queue.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    finish(.failure(PostgresError(.timeout, "Timed out after \(Int(timeout))s connecting to \(endpoint)")))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            once.withLock { $0.cancelled = true }
            connection.cancel()
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let connection = self.connection
        let endpoint = self.endpoint
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(bytes), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: PostgresError(.network, "Failed to send to \(endpoint): \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> [UInt8] {
        let connection = self.connection
        let endpoint = self.endpoint
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if let error {
                    continuation.resume(throwing: PostgresError(.network, "Connection to \(endpoint) failed: \(error.localizedDescription)"))
                } else if isComplete {
                    continuation.resume(throwing: PostgresError(.connectionClosed, "\(endpoint) closed the connection"))
                } else {
                    continuation.resume(throwing: PostgresError(.network, "Connection to \(endpoint) returned no data"))
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    deinit {
        connection.cancel()
    }

    // MARK: Facts

    private static func remote(of connection: NWConnection) -> Endpoint? {
        guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else { return nil }
        let text: String
        switch host {
        case let .ipv4(address): text = "\(address)"
        case let .ipv6(address): text = "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)"
        case let .name(name, _): text = name
        @unknown default: return nil
        }
        return Endpoint(host: text, port: Int(port.rawValue))
    }

    private static func tlsVersion(of connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        switch sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) {
        case .TLSv13: return "TLS 1.3"
        case .TLSv12: return "TLS 1.2"
        case .TLSv11: return "TLS 1.1"
        case .TLSv10: return "TLS 1.0"
        default: return "TLS"
        }
    }

    static func describe(_ error: NWError, endpoint: Endpoint, tls: TLSConfiguration?,
                         verification: PeerCertificateVerifier.Failure? = nil) -> PostgresError {
        if let verification {
            return PostgresError(.tls, "TLS connection to \(endpoint) failed: \(verification.message)")
        }
        switch error {
        case let .posix(code):
            switch code {
            case .ENOTSUP where tls != nil:
                return .serverRefusedTLS(endpoint)
            case .ECONNREFUSED:
                return PostgresError(.network, "Connection refused by \(endpoint). Is PostgreSQL running and listening on that address?")
            case .ETIMEDOUT:
                return PostgresError(.timeout, "Timed out connecting to \(endpoint)")
            case .EHOSTUNREACH, .ENETUNREACH:
                return PostgresError(.network, "\(endpoint) is unreachable from this network")
            case .ECONNRESET where tls != nil:
                return PostgresError(.tls, "\(endpoint) closed the connection during TLS negotiation")
            default:
                return PostgresError(.network, "Could not connect to \(endpoint): \(error.localizedDescription)")
            }
        case .dns:
            return PostgresError(.dns, "Could not resolve host \(endpoint.host)")
        case let .tls(status):
            return TLSSetup.describe(status: status, endpoint: endpoint, mode: tls?.mode)
        default:
            return PostgresError(.network, "Could not connect to \(endpoint): \(error.localizedDescription)")
        }
    }
}

extension PostgresError {
    static let serverRefusedTLSMarker = "does not accept TLS connections"

    static func serverRefusedTLS(_ endpoint: Endpoint) -> PostgresError {
        PostgresError(.tls, "\(endpoint) \(serverRefusedTLSMarker) (it answered the SSLRequest with “N”). Use SSL mode “Prefer” or “Disable”, or enable ssl on the server.")
    }

    /// The server answered SSLRequest with `N` (or an error): `prefer` falls back to a plain connection.
    public var isServerRefusedTLS: Bool { kind == .tls && message.contains(Self.serverRefusedTLSMarker) }
}

/// Builds TLS options: minimum TLS 1.2, SNI, ALPN for direct TLS and certificate verification per sslmode.
enum TLSSetup {
    static func options(for configuration: TLSConfiguration, queue: DispatchQueue,
                        failure: OSAllocatedUnfairLock<PeerCertificateVerifier.Failure?>) throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        let serverName = configuration.serverName.trimmingCharacters(in: .whitespaces)
        if !serverName.isEmpty, !isIPAddress(serverName) {
            serverName.withCString { sec_protocol_options_set_tls_server_name(security, $0) }
        }
        if configuration.negotiation == .direct {
            sec_protocol_options_add_tls_application_protocol(security, "postgresql")
        }
        let anchors = try configuration.rootCertificatePath.map(loadCertificates)
        let mode = configuration.mode
        if mode == .verifyFull, serverName.isEmpty {
            throw PostgresError(.tls, "SSL mode “verify-full” needs a host name to check the server certificate against")
        }
        let verifyHost: String? = mode == .verifyFull ? serverName : nil
        sec_protocol_options_set_verify_block(security, { _, trust, complete in
            guard mode.verifiesChain else {
                complete(true) // require/prefer: encryption without authentication (as libpq)
                return
            }
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            switch PeerCertificateVerifier.evaluate(secTrust, anchors: anchors, hostName: verifyHost) {
            case .success:
                complete(true)
            case let .failure(reason):
                failure.withLock { $0 = reason }
                complete(false)
            }
        }, queue)
        return options
    }

    /// Certificates from a PEM bundle (or a single DER file).
    static func loadCertificates(path: String) throws -> [SecCertificate] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else {
            throw PostgresError(.tls, "Could not read the CA certificate file \(url.path)")
        }
        var certificates: [SecCertificate] = []
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("-----BEGIN CERTIFICATE-----") {
            var remainder = Substring(text)
            while let begin = remainder.range(of: "-----BEGIN CERTIFICATE-----"),
                  let end = remainder.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<remainder.endIndex) {
                let body = remainder[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
                if let der = Data(base64Encoded: String(body)), let certificate = SecCertificateCreateWithData(nil, der as CFData) {
                    certificates.append(certificate)
                }
                remainder = remainder[end.upperBound...]
                if certificates.count > 500 { break }
            }
        } else if let certificate = SecCertificateCreateWithData(nil, data as CFData) {
            certificates.append(certificate)
        }
        guard !certificates.isEmpty else { throw PostgresError(.tls, "\(url.lastPathComponent) contains no certificates") }
        return certificates
    }

    static func isIPAddress(_ host: String) -> Bool {
        IPv4Address(host) != nil || IPv6Address(host) != nil
    }

    static func describe(status: OSStatus, endpoint: Endpoint, mode: SSLMode?) -> PostgresError {
        let reason: String
        switch status {
        case errSSLXCertChainInvalid, errSSLUnknownRootCert, errSSLNoRootCert, errSSLBadCert, errSSLHostNameMismatch,
             errSSLPeerBadCert, errSSLPeerCertUnknown, errSSLPeerUnknownCA, errSSLCertExpired, errSSLCertNotYetValid, -9808, -9813:
            reason = mode == .verifyFull
                ? "the server certificate could not be verified for this host name (check the CA file and that the certificate matches the host)"
                : "the server certificate could not be verified (check the CA file)"
        case errSSLProtocol, errSSLPeerProtocolVersion, errSSLNegotiation, errSSLPeerHandshakeFail:
            reason = "TLS negotiation failed (the server may only support TLS versions older than 1.2)"
        case errSSLClosedAbort, errSSLClosedGraceful:
            reason = "the server closed the connection during the TLS handshake"
        default:
            reason = "TLS error \(status)"
        }
        return PostgresError(.tls, "TLS connection to \(endpoint) failed: \(reason)")
    }
}

/// Sends PostgreSQL's SSLRequest, reads the one-byte answer and then becomes transparent so TLS
/// handshakes on the same TCP connection. Bytes after `S` go to TLS, never to the protocol parser.
final class SSLRequestFramer: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: SSLRequestFramer.self)
    static var label: String { "postgresql-sslrequest" }

    private static let sslRequest: [UInt8] = [0, 0, 0, 8, 0x04, 0xD2, 0x16, 0x2F]

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.writeOutput(data: Self.sslRequest)
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var answer: UInt8?
        _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 1) { buffer, _ in
            guard let buffer, let first = buffer.first else { return 0 }
            answer = first
            return 1
        }
        guard let answer else { return 1 }
        if answer == UInt8(ascii: "S") {
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
        } else {
            // `N` (no TLS) or `E` (a server too old to understand SSLRequest).
            framer.markFailed(error: .posix(.ENOTSUP))
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
