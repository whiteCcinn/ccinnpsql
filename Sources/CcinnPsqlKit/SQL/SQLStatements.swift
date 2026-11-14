import Foundation

/// One statement of a script. `range` is in UTF-16 offsets of the whole script and excludes the terminating
/// semicolon; `text` is the exact source in that range (comments inside are kept).
public struct SQLStatement: Sendable, Equatable {
    public let text: String
    public let range: Range<Int>

    public init(text: String, range: Range<Int>) {
        self.text = text
        self.range = range
    }
}

public enum SQLStatementSplitter {
    /// Splits on semicolons outside strings, dollar quotes, quoted identifiers and comments. Statements made only
    /// of comments/whitespace are dropped.
    public static func split(_ script: String) -> [SQLStatement] {
        let lexer = SQLLexer(script)
        return split(lexer: lexer, tokens: lexer.tokens())
    }

    public static func split(lexer: SQLLexer, tokens: [SQLToken]) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var firstSignificant: Int?
        var lastSignificantEnd = 0
        // `CREATE RULE … DO ALSO (a; b)` and `BEGIN ATOMIC … END` bodies contain semicolons inside parentheses / blocks.
        var depth = 0
        var atomicDepth = 0
        var previousWord = ""
        func flush() {
            if let start = firstSignificant {
                let range = start..<lastSignificantEnd
                statements.append(SQLStatement(text: lexer.text(in: range), range: range))
            }
            firstSignificant = nil
            depth = 0
            atomicDepth = 0
        }
        for token in tokens {
            if token.kind == .comment {
                // Leading comments belong to no statement; inner comments stay inside the range.
                if firstSignificant != nil { lastSignificantEnd = max(lastSignificantEnd, token.range.upperBound) }
                continue
            }
            if token.kind == .punctuation {
                switch lexer.units[token.range.lowerBound] {
                case 0x28: depth += 1
                case 0x29: depth = max(0, depth - 1)
                case 0x3B where depth == 0 && atomicDepth == 0:
                    flush()
                    previousWord = ""
                    continue
                default: break
                }
            }
            let word = lexer.word(of: token)
            if word == "ATOMIC", previousWord == "BEGIN" { atomicDepth += 1 }
            if word == "END", atomicDepth > 0 { atomicDepth -= 1 }
            previousWord = word
            if firstSignificant == nil { firstSignificant = token.range.lowerBound }
            lastSignificantEnd = token.range.upperBound
        }
        flush()
        return statements
    }

    /// The statement containing `offset` (UTF-16). A cursor right after a statement's `;` or in the blank space
    /// after it belongs to that statement.
    public static func statement(at offset: Int, in script: String) -> SQLStatement? {
        let statements = split(script)
        guard !statements.isEmpty else { return nil }
        if let containing = statements.first(where: { $0.range.lowerBound <= offset && offset <= $0.range.upperBound }) {
            return containing
        }
        return statements.last { $0.range.upperBound <= offset } ?? statements.first
    }
}

/// Significant tokens of one statement with their upper-cased words, shared by classification, the guard and
/// auto-LIMIT.
struct StatementWords {
    let lexer: SQLLexer
    let tokens: [SQLToken]
    let words: [String]

    init(_ statement: String) {
        let lexer = SQLLexer(statement)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        self.lexer = lexer
        self.tokens = tokens
        words = tokens.map { lexer.word(of: $0) }
    }

    func isPunctuation(_ index: Int, _ character: String) -> Bool {
        tokens.indices.contains(index) && tokens[index].kind == .punctuation && words[index] == character
    }

    func isWord(_ index: Int, _ word: String) -> Bool {
        tokens.indices.contains(index) && (tokens[index].kind == .keyword || tokens[index].kind == .identifier) && words[index] == word
    }

    /// Index of the `)` matching the `(` at `open` (or `tokens.count`).
    func matchingParen(_ open: Int) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            if isPunctuation(index, "(") { depth += 1 }
            if isPunctuation(index, ")") {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return tokens.count
    }

    /// Skips leading `(` of a parenthesised query.
    func firstWordIndex(from start: Int = 0) -> Int {
        var index = start
        while isPunctuation(index, "(") { index += 1 }
        return index
    }
}

/// What kind of statement a text is; drives auto-LIMIT, history, confirmation UI and the read-only guard.
public enum SQLStatementKind: Sendable, Equatable {
    case query
    case explain
    case show
    case set
    case transaction
    case dataModification
    case definition
    case maintenance
    case administration
    case other

    public static func of(_ statement: String) -> SQLStatementKind {
        let analysis = StatementWords(statement)
        return classify(analysis, from: 0)
    }

    static func classify(_ analysis: StatementWords, from start: Int) -> SQLStatementKind {
        let words = analysis.words
        let first = analysis.firstWordIndex(from: start)
        guard first < words.count else { return .other }
        switch words[first] {
        case "SELECT", "VALUES", "TABLE":
            return selectWritesData(analysis, from: first) ? .dataModification : .query
        case "WITH":
            return classifyWith(analysis, at: first)
        case "EXPLAIN":
            let (analyze, body) = explainTarget(analysis, at: first)
            if analyze, body < words.count, classify(analysis, from: body).isMutation { return .dataModification }
            return .explain
        case "SHOW":
            return .show
        case "SET", "RESET":
            if analysis.isWord(first + 1, "SESSION"), analysis.isWord(first + 2, "AUTHORIZATION") { return .administration }
            return .set
        case "BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE":
            return .transaction
        case "INSERT", "UPDATE", "DELETE", "MERGE", "TRUNCATE", "CALL", "DO", "REFRESH", "LOCK", "NOTIFY", "IMPORT":
            return .dataModification
        case "COPY":
            return classifyCopy(analysis, at: first)
        case "CREATE", "ALTER", "DROP", "COMMENT", "SECURITY":
            return .definition
        case "VACUUM", "ANALYZE", "ANALYSE", "CLUSTER", "REINDEX", "CHECKPOINT":
            return .maintenance
        case "GRANT", "REVOKE", "REASSIGN", "LOAD", "PREPARE":
            if words[first] == "PREPARE", !analysis.isWord(first + 1, "TRANSACTION") {
                // PREPARE name [(types)] AS statement
                if let asIndex = words[first...].firstIndex(of: "AS") { return classify(analysis, from: asIndex + 1) }
            }
            return .administration
        case "LISTEN", "UNLISTEN", "DISCARD", "DEALLOCATE":
            return .set
        case "DECLARE", "FETCH", "MOVE", "CLOSE":
            return .query
        default:
            return .other
        }
    }

    /// `WITH [RECURSIVE] a AS [NOT] [MATERIALIZED] (…), … <main>`: a data-modifying CTE or main statement is a mutation.
    static func classifyWith(_ analysis: StatementWords, at withIndex: Int) -> SQLStatementKind {
        var index = withIndex + 1
        if analysis.isWord(index, "RECURSIVE") { index += 1 }
        var cteModifies = false
        while index < analysis.tokens.count {
            // name [(columns)] AS [NOT] [MATERIALIZED] ( body )
            index += 1
            if analysis.isPunctuation(index, "(") { index = analysis.matchingParen(index) + 1 }
            guard analysis.isWord(index, "AS") else { break }
            index += 1
            if analysis.isWord(index, "NOT") { index += 1 }
            if analysis.isWord(index, "MATERIALIZED") { index += 1 }
            guard analysis.isPunctuation(index, "(") else { break }
            let close = analysis.matchingParen(index)
            if classify(analysis, from: index + 1).isMutation { cteModifies = true }
            index = close + 1
            // SEARCH/CYCLE clauses of recursive CTEs.
            while index < analysis.tokens.count, analysis.isWord(index, "SEARCH") || analysis.isWord(index, "CYCLE") {
                while index < analysis.tokens.count, !analysis.isPunctuation(index, ","), !["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "VALUES", "TABLE"].contains(analysis.words[index]) {
                    index += 1
                }
            }
            if analysis.isPunctuation(index, ",") {
                index += 1
                continue
            }
            break
        }
        let main = classify(analysis, from: index)
        if cteModifies || main.isMutation { return .dataModification }
        return main == .other ? .other : main
    }

    /// `COPY table [(cols)] FROM …` loads data; `COPY {table | (query)} TO STDOUT` is an export; `TO 'file'` and
    /// `PROGRAM` touch the server's file system or run programs.
    static func classifyCopy(_ analysis: StatementWords, at copyIndex: Int) -> SQLStatementKind {
        var index = copyIndex + 1
        if analysis.isPunctuation(index, "(") {
            index = analysis.matchingParen(index) + 1
        } else {
            while index < analysis.tokens.count, analysis.tokens[index].kind != .punctuation || analysis.isPunctuation(index, ".") {
                if analysis.words[index] == "FROM" || analysis.words[index] == "TO" { break }
                index += 1
            }
            if analysis.isPunctuation(index, "(") { index = analysis.matchingParen(index) + 1 }
        }
        guard index < analysis.words.count else { return .other }
        switch analysis.words[index] {
        case "FROM": return .dataModification
        case "TO":
            if analysis.isWord(index + 1, "STDOUT") { return .query }
            if analysis.isWord(index + 1, "PROGRAM") { return .administration }
            return .administration
        default: return .other
        }
    }

    /// `SELECT … INTO new_table` (outside parentheses) creates a table.
    static func selectWritesData(_ analysis: StatementWords, from start: Int) -> Bool {
        var depth = 0
        for index in start..<analysis.tokens.count {
            if analysis.isPunctuation(index, "(") { depth += 1 }
            if analysis.isPunctuation(index, ")") { depth = max(0, depth - 1) }
            if depth == 0, analysis.tokens[index].kind == .keyword, analysis.words[index] == "INTO" { return true }
        }
        return false
    }

    /// Whether EXPLAIN executes (ANALYZE) and the index of the explained statement.
    static func explainTarget(_ analysis: StatementWords, at explainIndex: Int) -> (analyze: Bool, body: Int) {
        var index = explainIndex + 1
        var analyze = false
        if analysis.isPunctuation(index, "(") {
            let close = analysis.matchingParen(index)
            var option = index + 1
            while option < close {
                if analysis.words[option] == "ANALYZE" || analysis.words[option] == "ANALYSE" {
                    let value = option + 1 < close ? analysis.words[option + 1].uppercased() : ""
                    analyze = !(value == "FALSE" || value == "OFF" || value == "0")
                }
                option += 1
            }
            index = close + 1
        } else {
            while index < analysis.words.count, ["ANALYZE", "ANALYSE", "VERBOSE"].contains(analysis.words[index]) {
                if analysis.words[index] != "VERBOSE" { analyze = true }
                index += 1
            }
        }
        return (analyze, index)
    }

    /// Statements that may change data, schema or server state (confirmed on protected connections).
    /// Unknown statements count as mutations.
    public var isMutation: Bool {
        switch self {
        case .dataModification, .definition, .maintenance, .administration, .other: true
        case .query, .explain, .show, .set, .transaction: false
        }
    }
}

/// Adds `LIMIT n` to top-level queries without one (workbench auto-limit).
public enum AutoLimit {
    public struct Outcome: Sendable, Equatable {
        public let sql: String
        public let applied: Bool
    }

    public static func apply(to sql: String, limit: Int) -> Outcome {
        guard limit > 0 else { return Outcome(sql: sql, applied: false) }
        let analysis = StatementWords(sql)
        guard let firstWord = analysis.words.first, firstWord == "SELECT" || firstWord == "WITH" || firstWord == "VALUES" || firstWord == "TABLE",
              SQLStatementKind.of(sql) == .query else { return Outcome(sql: sql, applied: false) }
        var depth = 0
        var lastSignificant: SQLToken?
        for (index, token) in analysis.tokens.enumerated() {
            if analysis.isPunctuation(index, "(") { depth += 1 }
            if analysis.isPunctuation(index, ")") { depth = max(0, depth - 1) }
            if analysis.isPunctuation(index, ";") { break }
            if depth == 0, token.kind == .keyword || token.kind == .identifier {
                switch analysis.words[index] {
                case "LIMIT", "FETCH", "INTO", "OFFSET":
                    // An explicit limit/fetch (OFFSET without LIMIT means "all rows from"); leave unchanged.
                    return Outcome(sql: sql, applied: false)
                case "FOR" where analysis.isWord(index + 1, "UPDATE") || analysis.isWord(index + 1, "SHARE")
                    || analysis.isWord(index + 1, "NO") || analysis.isWord(index + 1, "KEY"):
                    // LIMIT must precede FOR UPDATE; keep the statement as written.
                    return Outcome(sql: sql, applied: false)
                default: break
                }
            }
            lastSignificant = token
        }
        guard let lastSignificant else { return Outcome(sql: sql, applied: false) }
        let insertAt = lastSignificant.range.upperBound
        let units = analysis.lexer.units
        let head = String(decoding: units[0..<insertAt], as: UTF16.self)
        let tail = String(decoding: units[insertAt...], as: UTF16.self)
        return Outcome(sql: head + " LIMIT \(limit)" + tail, applied: true)
    }
}
