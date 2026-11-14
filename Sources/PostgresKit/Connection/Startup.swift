import Foundation
import PostgresWire

/// What the server told us during startup.
struct StartupResult: Sendable {
    var backendKey: BackendKey?
    var parameters: [String: String] = [:]
    var transactionStatus: TransactionStatus = .idle
    var authenticationMethod: String = "trust"
}

/// StartupMessage → authentication exchange → ParameterStatus/BackendKeyData → ReadyForQuery (design D3).
enum Startup {
    /// Bounds on a hostile or broken server.
    static let maxAuthenticationSteps = 8
    static let maxStartupMessages = 4_096

    static func perform(channel: inout MessageChannel, configuration: ConnectionConfiguration) async throws -> StartupResult {
        try await channel.send(FrontendMessage.startup(parameters: configuration.startupParameters))
        var result = StartupResult()
        var scram: SCRAMSHA256Client?
        var authenticationSteps = 0
        var authenticated = false
        for _ in 0..<maxStartupMessages {
            let message = try await channel.read()
            switch try message.parse() {
            case let .authentication(request):
                authenticationSteps += 1
                guard authenticationSteps <= maxAuthenticationSteps else {
                    throw PostgresError(.protocolViolation, "The server did not finish authentication")
                }
                switch request {
                case .ok:
                    if let scram, !scram.isVerified {
                        throw PostgresError(.authentication, "The server accepted the login without proving it knows the password (missing SCRAM signature); refusing to continue")
                    }
                    authenticated = true
                case .cleartextPassword:
                    guard configuration.allowCleartextPassword else {
                        throw PostgresError(.authentication, "The server asked for the password in clear text (method “password”). Enable “Allow clear-text password” for this connection, preferably only with TLS or an SSH tunnel.")
                    }
                    try requirePassword(configuration)
                    result.authenticationMethod = "password"
                    try await channel.send(FrontendMessage.password(configuration.password))
                case let .md5Password(salt):
                    try requirePassword(configuration)
                    result.authenticationMethod = "md5"
                    try await channel.send(FrontendMessage.password(
                        PostgresAuth.md5Response(user: configuration.username, password: configuration.password, salt: salt)))
                case let .sasl(mechanisms):
                    guard mechanisms.contains(SCRAMSHA256Client.mechanism) else {
                        let offered = mechanisms.joined(separator: ", ")
                        throw PostgresError(.authentication, "The server requires an unsupported SASL mechanism (\(offered)). SCRAM channel binding (-PLUS) only is not supported.")
                    }
                    try requirePassword(configuration)
                    result.authenticationMethod = "scram-sha-256"
                    var client = SCRAMSHA256Client(password: configuration.password)
                    try await channel.send(FrontendMessage.saslInitialResponse(mechanism: SCRAMSHA256Client.mechanism,
                                                                               data: client.clientFirstMessage()))
                    scram = client
                case let .saslContinue(data):
                    guard var client = scram else { throw PostgresError(.protocolViolation, "Unexpected SASL continuation") }
                    let final = try client.clientFinalMessage(serverFirst: data)
                    scram = client
                    try await channel.send(FrontendMessage.saslResponse(final))
                case let .saslFinal(data):
                    guard var client = scram else { throw PostgresError(.protocolViolation, "Unexpected SASL final message") }
                    try client.verifyServerFinal(data)
                    scram = client
                case let .unsupported(code):
                    throw PostgresError(.authentication, unsupportedMessage(code))
                }
            case let .backendKeyData(processID, secretKey):
                result.backendKey = BackendKey(processID: processID, secretKey: secretKey)
            case let .parameterStatus(name, value):
                guard result.parameters.count < 256 else { continue }
                result.parameters[name] = value
            case .noticeResponse, .negotiateProtocolVersion:
                continue
            case let .errorResponse(fields):
                throw PostgresError.server(fields)
            case let .readyForQuery(status):
                guard authenticated else { throw PostgresError(.protocolViolation, "ReadyForQuery before authentication") }
                result.transactionStatus = status
                return result
            default:
                throw PostgresError(.protocolViolation, "Unexpected message during startup")
            }
        }
        throw PostgresError(.protocolViolation, "The server sent too many startup messages")
    }

    static func requirePassword(_ configuration: ConnectionConfiguration) throws {
        guard !configuration.password.isEmpty else {
            throw PostgresError(.authentication, "The server requires a password for user “\(configuration.username)”")
        }
    }

    static func unsupportedMessage(_ code: Int32) -> String {
        switch code {
        case 2: "The server requires Kerberos V5 authentication, which CcinnPsql does not support"
        case 6: "The server requires SCM credential authentication, which only works over Unix sockets"
        case 7, 8: "The server requires GSSAPI authentication, which CcinnPsql does not support"
        case 9: "The server requires SSPI authentication, which CcinnPsql does not support"
        default: "The server requires an unsupported authentication method (code \(code))"
        }
    }
}
