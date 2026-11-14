import Foundation

/// Classifies statements that change session state, so a session can replay them after a reconnect.
public enum SessionSettingChange: Equatable, Sendable {
    /// A session-level `SET …` (also `SET ROLE`, `SET search_path`, `SET TIME ZONE`, `SET SESSION AUTHORIZATION`)
    /// or `SELECT set_config(…, false)`; `name` is the lower-cased parameter.
    case set(name: String, statement: String)
    case reset(name: String)
    /// `RESET ALL`, `DISCARD ALL`, `RESET SESSION AUTHORIZATION` and friends.
    case resetAll
    /// A transaction boundary that decides whether pending settings stick.
    case commit
    case rollback

    /// Recognises one statement (comments and trailing semicolons allowed). `nil` for everything else,
    /// including transaction-scoped `SET LOCAL`, `SET TRANSACTION` and `SET CONSTRAINTS`.
    public static func parse(_ sql: String) -> SessionSettingChange? {
        let text = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(text)
        while body.hasSuffix(";") { body = body.dropLast() }
        body = body.trimmingSuffixWhitespace()
        let words = body.split(whereSeparator: \.isWhitespace).prefix(4).map { $0.lowercased() }
        guard let first = words.first else { return nil }
        let statement = String(body)
        switch first {
        case "set":
            guard words.count >= 2 else { return nil }
            var nameIndex = 1
            if words[1] == "session" {
                guard words.count >= 3 else { return nil }
                if words[2] == "characteristics" { return .set(name: "default_transaction_characteristics", statement: statement) }
                if words[2] == "authorization" { return .set(name: "session_authorization", statement: statement) }
                nameIndex = 2
            }
            let name = words[nameIndex]
            switch name {
            case "local", "transaction", "constraints": return nil
            case "role": return .set(name: "role", statement: statement)
            case "time": return .set(name: "timezone", statement: statement)
            case "names": return .set(name: "client_encoding", statement: statement)
            case "schema": return .set(name: "search_path", statement: statement)
            default:
                let parameter = name.split(whereSeparator: { $0 == "=" }).first.map(String.init) ?? name
                guard !parameter.isEmpty else { return nil }
                return .set(name: parameter, statement: statement)
            }
        case "reset":
            guard words.count >= 2 else { return nil }
            if words[1] == "all" { return .resetAll }
            if words[1] == "session", words.count >= 3, words[2] == "authorization" { return .reset(name: "session_authorization") }
            if words[1] == "role" { return .reset(name: "role") }
            return .reset(name: words[1])
        case "discard":
            return words.count >= 2 && words[1] == "all" ? .resetAll : nil
        case "commit", "end":
            return .commit
        case "rollback", "abort":
            // ROLLBACK TO SAVEPOINT keeps the transaction open.
            return words.count >= 2 && (words[1] == "to" || (words.count >= 3 && words[2] == "to")) ? nil : .rollback
        case "select":
            // SELECT set_config('name', 'value', false) — session scoped.
            let lowered = statement.lowercased()
            guard lowered.hasPrefix("select set_config("), lowered.hasSuffix("false)") || lowered.hasSuffix("false )"),
                  let open = statement.firstIndex(of: "'") else { return nil }
            let rest = statement[statement.index(after: open)...]
            guard let close = rest.firstIndex(of: "'") else { return nil }
            return .set(name: rest[..<close].lowercased(), statement: statement)
        default:
            return nil
        }
    }

    static func strippingLeadingComments(_ sql: String) -> String {
        var text = Substring(sql)
        while true {
            text = text.drop(while: { $0.isWhitespace })
            if text.hasPrefix("--") {
                text = text.drop(while: { $0 != "\n" })
            } else if text.hasPrefix("/*") {
                guard let end = text.range(of: "*/") else { return "" }
                text = text[end.upperBound...]
            } else {
                return String(text)
            }
        }
    }
}

/// Session settings that a reconnect replays, honouring transactions: settings made inside a transaction only
/// stick when it commits (PostgreSQL reverts them on rollback).
public struct SessionSettingsLog: Sendable, Equatable {
    public private(set) var committed: [(name: String, statement: String)] = []
    private var pending: [SessionSettingChange] = []
    public static let maxSettings = 64

    public init() {}

    public static func == (lhs: SessionSettingsLog, rhs: SessionSettingsLog) -> Bool {
        lhs.committed.map(\.statement) == rhs.committed.map(\.statement) && lhs.pending == rhs.pending
    }

    /// Records a successfully executed statement. `inTransaction` is the status after it ran.
    public mutating func record(_ sql: String, inTransaction: Bool) {
        guard let change = SessionSettingChange.parse(sql) else {
            if !inTransaction { pending.removeAll() }
            return
        }
        switch change {
        case .commit:
            for change in pending { apply(change) }
            pending.removeAll()
        case .rollback:
            pending.removeAll()
        default:
            if inTransaction { pending.append(change) } else { apply(change) }
        }
    }

    /// The transaction failed or was rolled back by the server (e.g. the connection dropped).
    public mutating func discardPending() {
        pending.removeAll()
    }

    private mutating func apply(_ change: SessionSettingChange) {
        switch change {
        case let .set(name, statement):
            committed.removeAll { $0.name == name }
            committed.append((name, statement))
            if committed.count > Self.maxSettings { committed.removeFirst(committed.count - Self.maxSettings) }
        case let .reset(name):
            committed.removeAll { $0.name == name }
        case .resetAll:
            committed.removeAll()
        case .commit, .rollback:
            break
        }
    }

    /// Statements to run on a fresh connection, in order.
    public var replayStatements: [String] { committed.map(\.statement) }
}

extension Substring {
    func trimmingSuffixWhitespace() -> Substring {
        var copy = self
        while let last = copy.last, last.isWhitespace { copy = copy.dropLast() }
        return copy
    }
}
