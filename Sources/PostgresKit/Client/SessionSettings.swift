import Foundation
import PostgresWire

/// Classifies statements that change session state, so a session can replay them after a reconnect.
public enum SessionSettingChange: Equatable, Sendable {
    /// A session-level `SET …` (also `SET ROLE`, `SET search_path`, `SET TIME ZONE`, `SET SESSION AUTHORIZATION`)
    /// or `SELECT set_config(…, false)`; `name` is the lower-cased parameter.
    case set(name: String, statement: String)
    case reset(name: String)
    /// `RESET ALL`, `DISCARD ALL`, `RESET SESSION AUTHORIZATION` and friends.
    case resetAll
    /// Transaction control that decides whether pending settings stick. `chain`: `AND CHAIN` opens the next
    /// transaction at once.
    case begin
    case commit(chain: Bool)
    case rollback(chain: Bool)
    case savepoint(String)
    case rollbackToSavepoint(String)
    case releaseSavepoint(String)

    /// Recognises one statement (comments and trailing semicolons allowed). `nil` for everything else,
    /// including transaction-scoped `SET LOCAL`, `SET TRANSACTION` and `SET CONSTRAINTS`.
    public static func parse(_ sql: String) -> SessionSettingChange? {
        let text = strippingLeadingComments(sql).trimmingCharacters(in: .whitespacesAndNewlines)
        var body = Substring(text)
        while body.hasSuffix(";") { body = body.dropLast() }
        body = body.trimmingSuffixWhitespace()
        let words = body.split(whereSeparator: \.isWhitespace).prefix(6).map { $0.lowercased() }
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
        case "begin", "start":
            return first == "start" && (words.count < 2 || words[1] != "transaction") ? nil : .begin
        case "commit", "end":
            // COMMIT PREPARED finishes a prepared transaction, not the session's.
            if words.count >= 2, words[1] == "prepared" { return nil }
            return .commit(chain: Self.chains(words))
        case "prepare":
            // PREPARE TRANSACTION keeps the session's settings like a commit does.
            return words.count >= 2 && words[1] == "transaction" ? .commit(chain: false) : nil
        case "rollback", "abort":
            if words.count >= 2, words[1] == "prepared" { return nil }
            if let to = words.firstIndex(of: "to") {
                var nameIndex = to + 1
                if nameIndex < words.count, words[nameIndex] == "savepoint" { nameIndex += 1 }
                return nameIndex < words.count ? .rollbackToSavepoint(Self.savepointName(words[nameIndex])) : nil
            }
            return .rollback(chain: Self.chains(words))
        case "savepoint":
            return words.count >= 2 ? .savepoint(Self.savepointName(words[1])) : nil
        case "release":
            guard words.count >= 2 else { return nil }
            let name = words[1] == "savepoint" && words.count >= 3 ? words[2] : words[1]
            return .releaseSavepoint(Self.savepointName(name))
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

    private static func chains(_ words: [String]) -> Bool {
        guard let index = words.firstIndex(of: "chain"), index > 0 else { return false }
        return words[index - 1] == "and"
    }

    private static func savepointName(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: "\";"))
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

/// Session settings that a reconnect replays, honouring transactions the way PostgreSQL does: settings made inside
/// a transaction stick only when it commits, `ROLLBACK TO SAVEPOINT` drops those made after the savepoint, and in
/// a simple-protocol batch the statements outside an explicit block form one implicit transaction that a later
/// error (or a cancel) rolls back.
public struct SessionSettingsLog: Sendable, Equatable {
    public private(set) var committed: [(name: String, statement: String)] = []
    /// Changes inside the open explicit transaction, with savepoint markers.
    private var pending: [PendingEntry] = []
    private var inTransaction = false
    /// The open transaction failed: COMMIT will roll it back unless ROLLBACK TO SAVEPOINT recovers it.
    private var aborted = false
    public static let maxSettings = 64

    private enum PendingEntry: Equatable, Sendable {
        case change(SessionSettingChange)
        case savepoint(String)
    }

    public init() {}

    public static func == (lhs: SessionSettingsLog, rhs: SessionSettingsLog) -> Bool {
        lhs.committed.map(\.statement) == rhs.committed.map(\.statement) && lhs.pending == rhs.pending
            && lhs.inTransaction == rhs.inTransaction && lhs.aborted == rhs.aborted
    }

    /// Records one sent message. `statements` are its statements in order, `completed` how many finished
    /// (CommandComplete), `failed` whether the message ended in an error or a cancel, `finalStatus` the
    /// transaction status the server reported at ReadyForQuery (authoritative when it disagrees).
    public mutating func recordBatch(_ statements: [String], completed: Int, failed: Bool, finalStatus: TransactionStatus) {
        var implicit: [SessionSettingChange] = []
        for statement in statements.prefix(max(0, completed)) {
            guard let change = SessionSettingChange.parse(statement) else { continue }
            switch change {
            case .begin:
                guard !inTransaction else { continue }
                // BEGIN turns the batch's implicit block into the explicit transaction.
                inTransaction = true
                aborted = false
                pending = implicit.map(PendingEntry.change)
                implicit.removeAll()
            case let .commit(chain):
                if !aborted {
                    for entry in pending { if case let .change(change) = entry { apply(change) } }
                    for change in implicit { apply(change) }
                }
                endTransaction(chain: chain)
                implicit.removeAll()
            case let .rollback(chain):
                endTransaction(chain: chain)
                implicit.removeAll()
            case let .savepoint(name):
                if inTransaction { pending.append(.savepoint(name)) }
            case let .rollbackToSavepoint(name):
                if inTransaction, let marker = pending.lastIndex(of: .savepoint(name)) {
                    pending.removeSubrange((marker + 1)...)
                    aborted = false
                }
            case let .releaseSavepoint(name):
                if inTransaction, let marker = pending.lastIndex(of: .savepoint(name)) {
                    // Releasing keeps the changes and drops this and every later savepoint.
                    let later = pending[(marker + 1)...].filter { if case .change = $0 { true } else { false } }
                    pending = Array(pending[..<marker]) + later
                }
            case .set, .reset, .resetAll:
                if inTransaction { pending.append(.change(change)) } else { implicit.append(change) }
            }
        }
        if failed {
            // The implicit block was rolled back; an explicit transaction is now aborted.
            if inTransaction { aborted = true }
        } else {
            for change in implicit { apply(change) }
        }
        switch finalStatus {
        case .idle where inTransaction:
            // Ended by something not parsed here (a procedure's COMMIT, a FATAL): replay nothing from it.
            endTransaction(chain: false)
        case .inTransaction where !inTransaction:
            inTransaction = true
        case .failedTransaction:
            inTransaction = true
            aborted = true
        default:
            break
        }
    }

    /// Aligns with the connection's status before a new message: a transaction that ended unseen (a reconnect,
    /// a server-side termination) keeps nothing, and later statements are not mistaken for part of it.
    public mutating func align(with status: TransactionStatus) {
        if status == .idle, inTransaction { endTransaction(chain: false) }
    }

    /// One statement that ran on its own. `inTransaction` is the status after it ran.
    public mutating func record(_ sql: String, inTransaction: Bool) {
        recordBatch([sql], completed: 1, failed: false, finalStatus: inTransaction ? .inTransaction : .idle)
    }

    /// The connection was lost: the server rolled back whatever transaction was open.
    public mutating func discardPending() {
        endTransaction(chain: false)
    }

    private mutating func endTransaction(chain: Bool) {
        pending.removeAll()
        aborted = false
        inTransaction = chain
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
        case .begin, .commit, .rollback, .savepoint, .rollbackToSavepoint, .releaseSavepoint:
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
