import Foundation
import PostgresWire

/// Every failure surfaced by PostgresKit. Messages are user-facing and never contain secrets.
public struct PostgresError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        case invalidArgument
        case network
        case timeout
        case dns
        case sshTunnel
        case tls
        case authentication
        /// The server rejected a statement (ErrorResponse below FATAL). The connection stays usable.
        case server
        case protocolViolation
        case cancelled
        case connectionClosed
        case busy
        case unsupported
    }

    public let kind: Kind
    public let message: String
    /// Fields of the server's ErrorResponse, when the failure came from the server.
    public let fields: ServerMessageFields?
    /// Notices the server sent before the error (e.g. `RAISE NOTICE` before an exception).
    public internal(set) var notices: [ServerMessageFields]

    public init(_ kind: Kind, _ message: String, fields: ServerMessageFields? = nil, notices: [ServerMessageFields] = []) {
        self.kind = kind
        self.message = message
        self.fields = fields
        self.notices = notices
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public var sqlState: String? { fields?.sqlState }
    /// 1-based character position of the error in the statement.
    public var position: Int? { fields?.position }
    public var detail: String? { fields?.detail }
    public var hint: String? { fields?.hint }

    public static func cancelled() -> PostgresError { PostgresError(.cancelled, "The operation was cancelled") }

    /// Maps an ErrorResponse. FATAL/PANIC errors end the session; authentication SQLSTATEs (28xxx) get their own kind.
    static func server(_ fields: ServerMessageFields) -> PostgresError {
        let message = fields.message.isEmpty ? "Server error \(fields.sqlState ?? "")" : fields.message
        let severity = fields.nonLocalizedSeverity ?? fields.severity
        let kind: Kind
        if fields.sqlState?.hasPrefix("28") == true {
            kind = .authentication
        } else if severity == "FATAL" || severity == "PANIC" {
            kind = .connectionClosed
        } else {
            kind = .server
        }
        return PostgresError(kind, message, fields: fields)
    }

    /// `57014`: canceled by CancelRequest, statement_timeout or similar.
    public var isQueryCanceled: Bool { sqlState == "57014" }

    /// Errors after which the connection must not be reused.
    public var breaksConnection: Bool {
        switch kind {
        case .server, .invalidArgument, .busy, .unsupported: false
        default: true
        }
    }

    /// One line with SQLSTATE, for logs and MCP results.
    public var summary: String {
        var text = message
        if let sqlState { text += " (SQLSTATE \(sqlState))" }
        return text
    }
}
