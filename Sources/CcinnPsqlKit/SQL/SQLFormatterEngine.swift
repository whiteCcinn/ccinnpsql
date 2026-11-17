import Foundation

// MARK: - Vocabulary

extension SQLFormatter {
    /// Words before which a statement-level (or subquery-level) clause starts on its own line.
    static let clauseWords: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "LIMIT", "OFFSET", "FETCH", "UNION",
                                           "INTERSECT", "EXCEPT", "VALUES", "SET", "WINDOW", "RETURNING"]
    /// Words that end a list for the comma look-ahead. Not VALUES and SET: they may be names (`select values, set from t`), and
    /// no list is followed directly by a VALUES or SET clause.
    static let listEndWords: Set<String> = clauseWords.subtracting(["VALUES", "SET"])
        .union(["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "ON", "USING", "INTO", "FOR"])
    /// Set operators: always keywords (reserved).
    static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT"]
    /// Statements that get clause layout; others only get normalised spacing.
    static let layoutStatements: Set<String> = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "VALUES", "CREATE", "EXPLAIN"]
    /// Words that may precede the query of an EXPLAIN without a break.
    static let queryPrefixWords: Set<String> = ["EXPLAIN", "ANALYZE", "ANALYSE", "VERBOSE"]
    /// Commands whose words run up to an object kind (`CREATE OR REPLACE VIEW`, `DROP TABLE IF EXISTS`).
    static let objectCommands: Set<String> = ["CREATE", "ALTER", "DROP", "REFRESH", "REINDEX", "REASSIGN"]
    /// Words that may stand between such a command and its object kind.
    static let commandModifiers: Set<String> = ["OR", "REPLACE", "TEMP", "TEMPORARY", "LOCAL", "GLOBAL", "UNLOGGED", "UNIQUE",
                                                "MATERIALIZED", "RECURSIVE", "FOREIGN", "DATA", "TRUSTED", "PROCEDURAL", "CONSTRAINT",
                                                "DEFAULT", "LARGE"]
    /// Object kinds after CREATE / ALTER / DROP; the name follows.
    static let objectKinds: Set<String> = ["TABLE", "VIEW", "INDEX", "FUNCTION", "PROCEDURE", "SCHEMA", "SEQUENCE", "TYPE", "EXTENSION",
                                           "TRIGGER", "ROLE", "USER", "DATABASE", "DOMAIN", "POLICY", "RULE", "AGGREGATE", "OPERATOR",
                                           "COLLATION", "PUBLICATION", "SUBSCRIPTION", "SERVER", "TABLESPACE", "ROUTINE", "STATISTICS",
                                           "LANGUAGE", "CAST", "WRAPPER", "SYSTEM", "GROUP", "OBJECT"]
    /// Options written between VACUUM / ANALYZE / EXPLAIN / CLUSTER and their target.
    static let commandPrefixOptions: Set<String> = ["FULL", "FREEZE", "VERBOSE", "ANALYZE", "ANALYSE"]
    /// Words that start a join operator.
    static let joinWords: Set<String> = ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER"]
    /// Keywords written directly before `(` like a function call.
    static let callLikeKeywords: Set<String> = {
        var words = Set(SQLFunctions.names)
        words.formUnion(["CAST", "COALESCE", "NULLIF", "GREATEST", "LEAST", "EXTRACT", "ROW", "ARRAY", "OVERLAY", "POSITION",
                         "SUBSTRING", "TRIM", "NORMALIZE", "TREAT", "GROUPING", "XMLELEMENT", "XMLFOREST", "XMLCONCAT", "XMLPARSE",
                         "XMLPI", "XMLROOT", "XMLSERIALIZE", "VARCHAR", "CHAR", "CHARACTER", "NUMERIC", "DECIMAL", "DEC", "TIMESTAMP",
                         "TIME", "BIT", "VARBIT", "FLOAT", "LEFT", "RIGHT", "MODE", "CUBE", "ROLLUP"])
        words.subtract(["IN", "VALUES", "AS", "ON", "USING", "EXISTS", "OVER", "FILTER", "AND", "OR", "NOT", "ANY", "ALL", "SOME",
                        "WHEN", "THEN", "ELSE", "END", "PARTITION", "INTO", "TABLE", "FROM", "WHERE", "SELECT", "WITH", "KEY", "RANGE",
                        "LIST", "HASH", "CHECK", "UNIQUE", "REFERENCES", "INHERITS", "INCLUDE"])
        return words
    }()
    /// `pg_get_keywords()` catcode `T`: keywords that may name a function or type (the same on PostgreSQL 13 to 18).
    static let typeFunctionNameKeywords: Set<String> = ["AUTHORIZATION", "BINARY", "COLLATION", "CONCURRENTLY", "CROSS", "CURRENT_SCHEMA",
                                                        "FREEZE", "FULL", "ILIKE", "INNER", "IS", "ISNULL", "JOIN", "LEFT", "LIKE",
                                                        "NATURAL", "NOTNULL", "OUTER", "OVERLAPS", "RIGHT", "SIMILAR", "TABLESAMPLE",
                                                        "VERBOSE"]
    /// Reserved words that are values, not operators: a `-` after them is binary.
    static let operandKeywords: Set<String> = ["NULL", "TRUE", "FALSE", "END", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP",
                                               "LOCALTIME", "LOCALTIMESTAMP", "CURRENT_USER", "SESSION_USER", "CURRENT_ROLE", "USER",
                                               "CURRENT_CATALOG", "CURRENT_SCHEMA", "SYSTEM_USER"]
}

// MARK: - Engine

extension SQLFormatter {
    struct Frame {
        enum Kind { case statement, subquery, list, paren }
        enum Clause { case none, select, from, whereLike, groupBy, orderBy, limit, join, on, set, values, with, window, returning, ddl, other }

        var kind: Kind
        /// Indent level of clauses (statement, subquery) or items (list) in this frame.
        var indent: Int
        /// Indent level of the line holding the opening `(`.
        var openIndent: Int
        /// Opened by `[` rather than `(`.
        var bracket = false
        var clause: Clause = .none
        var listBreak = false
        var betweenPending = false
        var cases: [CaseInfo] = []
        /// The command running in this frame (`INSERT`, `UPDATE`, …), when one was recognised.
        var command: String?
        /// An `UPDATE` command whose `SET` has not come yet.
        var pendingUpdate: Int?
        /// An `INSERT` command (or a MERGE action's) whose rows or query have not come yet: `VALUES (…)` here is its rows.
        var pendingInsert = false
        /// A window specification (`OVER (…)`, `WINDOW w AS (…)`), and whether its frame clause (`ROWS …`) started.
        var window = false
        var windowFrame = false
        /// Sort items are listed here (`ORDER BY`, index elements): `NULLS FIRST / LAST` are keywords.
        var sortItems = false
        /// Inside a locking clause (`FOR [NO KEY] UPDATE | [KEY] SHARE …`).
        var locking = false

        var allowsClauses: Bool { kind == .statement || kind == .subquery }
    }

    struct CaseInfo {
        var multiline: Bool
        var indent: Int
        var endIndex: Int?
    }

    /// Lays out one run of tokens. `tokens` may be a slice of the lexer's tokens (a selection); their ranges index
    /// `lexer.units`.
    struct Engine {
        let lexer: SQLLexer
        let tokens: [SQLToken]
        let options: SQLFormatOptions
        /// Written between lines: the input's own line break (`\n`, `\r\n` or `\r`).
        let lineBreak: String
        /// Text of keyword and identifier tokens with ASCII letters upper-cased, "" for a word next to `.` (part of a
        /// qualified name, never a keyword); the raw text of other tokens.
        let words: [String]
        /// For each `(` / `[`, the index of its closing token (-1 when unbalanced).
        private let closers: [Int]
        /// For each CASE, the index of its END (-1 when there is none) and its number of WHEN / ELSE branches.
        private let caseEnds: [Int]
        private let caseBranches: [Int]
        /// For each token, the `JOIN` that completes a join operator starting there (-1 when none).
        private let joinEnds: [Int]
        /// Reserved keywords, then (after `run`) every token whose case may change.
        private(set) var caseChangeable = Set<Int>()
        /// Keywords whose position proves them keywords.
        private var structural = Set<Int>()
        /// Words used as names (next to `.`, a label after AS, a table name): never changed, never keywords.
        private var names = Set<Int>()

        private var output = ""
        private var writtenUnits = 0
        private let growthLimit: Int
        private var failure: SQLFormatError?
        private var lineIndent = 0
        private var atLineStart = true
        private var pendingBreak: (indent: Int, blank: Bool)?
        /// Comments that started their own line (and comments after them on that line), written before the next token
        /// at that token's indent.
        private var heldComments: [(index: Int, sameLine: Bool)] = []
        private var frames: [Frame] = [Frame(kind: .statement, indent: 0, openIndent: 0)]
        private var lastWritten: Int?
        private var lastSignificant: Int?
        private var attachNext = false
        /// Upper-cased keywords and identifiers of the current statement ("" for other tokens and for keywords used as
        /// names).
        private var statementWords: [String] = []
        /// `statementWords` holds only words that may precede a query (`EXPLAIN ANALYZE`), kept as they are appended.
        private var onlyQueryPrefix = true
        private var statementHasSelect = false
        /// The fragment being formatted starts inside a statement (a selection): its first words are not command words.
        private var continuesStatement: Bool
        private var layout = true
        private var listHeadEnd: Int?
        /// After INTO / TABLE / VIEW / REFERENCES: 1 = expecting the name, 2 = inside the (qualified) name.
        private var tableNameState = 0
        /// Last word of a multi-word join operator being written.
        private var joinWordsThrough: Int?
        /// In a CREATE statement, clause layout starts with its query (`CREATE VIEW v AS SELECT …`).
        private var queryStarted = false
        /// Still in the command words at the start of the statement (`CREATE OR REPLACE VIEW`, `DROP TABLE IF EXISTS`).
        private var inCommandWords: Bool
        /// The object kind of a CREATE / ALTER / DROP (`TABLE`, `TRIGGER`, …) once seen.
        private var commandObject: String?
        /// `BEGIN ATOMIC … END` bodies: their `;` do not end the statement.
        private var atomicDepth = 0
        /// Inside `EXPLAIN (ANALYZE, FORMAT JSON)`-style option lists.
        private var inCommandOptions = false

        /// `tokens` may be part of a text (a selection); `dotBefore` / `dotAfter`: the text has `.` right before / after them.
        init(lexer: SQLLexer, tokens: [SQLToken], options: SQLFormatOptions, continuesStatement: Bool, lineBreak: String,
             dotBefore: Bool = false, dotAfter: Bool = false) {
            self.lexer = lexer
            self.tokens = tokens
            self.options = options
            self.lineBreak = lineBreak
            self.continuesStatement = continuesStatement
            inCommandWords = !continuesStatement
            var words = tokens.map { token in
                token.kind == .keyword || token.kind == .identifier ? lexer.asciiUppercased(token.range) : lexer.text(of: token)
            }
            // A word right before or after `.` is part of a qualified name (`t.end`, `end.x`, `over.a`): it never opens or
            // closes a structure, never proves a position and never changes case, whatever it spells.
            let isWord = { (index: Int) in tokens[index].kind == .keyword || tokens[index].kind == .identifier }
            let isDot = { (index: Int) in tokens[index].kind == .punctuation && words[index] == "." }
            var previous: Int?
            for index in tokens.indices where tokens[index].kind != .comment {
                if let previous {
                    if isDot(previous), isWord(index) { names.insert(index) }
                    if isDot(index), isWord(previous) { names.insert(previous) }
                } else if dotBefore, isWord(index) {
                    names.insert(index)
                }
                previous = index
            }
            if dotAfter, let previous, isWord(previous) { names.insert(previous) }
            for index in names { words[index] = "" }
            self.words = words
            for index in tokens.indices where tokens[index].kind == .keyword && SQLFormatter.reservedKeywords.contains(words[index]) {
                caseChangeable.insert(index)
            }
            let inputUnits = (tokens.first?.range.lowerBound).map { (tokens.last?.range.upperBound ?? $0) - $0 } ?? 0
            growthLimit = inputUnits * SQLFormatter.maximumGrowth + SQLFormatter.growthAllowance
            (closers, caseEnds, caseBranches) = Self.structure(tokens: tokens, words: words)
            joinEnds = Self.joinEnds(tokens: tokens, words: words)
        }

        /// Matching brackets and CASE … END pairs, in one pass. (A CASE or END next to `.` is a name: its word is "".)
        private static func structure(tokens: [SQLToken], words: [String]) -> ([Int], [Int], [Int]) {
            var closers = Array(repeating: -1, count: tokens.count)
            var caseEnds = Array(repeating: -1, count: tokens.count)
            var caseBranches = Array(repeating: 0, count: tokens.count)
            var openers: [Int] = []
            var cases: [(index: Int, depth: Int)] = []
            for index in tokens.indices {
                let kind = tokens[index].kind
                guard kind != .comment else { continue }
                let word = words[index]
                if kind == .punctuation {
                    switch word {
                    case "(", "[":
                        openers.append(index)
                    case ")", "]":
                        if let open = openers.last, (words[open] == "(") == (word == ")") {
                            openers.removeLast()
                            closers[open] = index
                        }
                        while let open = cases.last, open.depth > openers.count { cases.removeLast() }
                    case ";":
                        cases.removeAll()
                    default:
                        break
                    }
                    continue
                }
                guard kind == .keyword else { continue }
                switch word {
                case "CASE":
                    cases.append((index, openers.count))
                case "WHEN", "ELSE":
                    if let open = cases.last, open.depth == openers.count { caseBranches[open.index] += 1 }
                case "END":
                    if let open = cases.last, open.depth == openers.count {
                        cases.removeLast()
                        caseEnds[open.index] = index
                    }
                default:
                    break
                }
            }
            return (closers, caseEnds, caseBranches)
        }

        /// Join operators, in one backward pass: `[NATURAL] [LEFT | RIGHT | FULL | INNER] [OUTER] JOIN`, `CROSS JOIN`. A token
        /// other than NATURAL completes one through OUTERs only; NATURAL also through LEFT / RIGHT / FULL / INNER.
        private static func joinEnds(tokens: [SQLToken], words: [String]) -> [Int] {
            var ends = Array(repeating: -1, count: tokens.count)
            var throughOuter = Array(repeating: -1, count: tokens.count) // JOIN, or OUTER … JOIN
            var throughAny = Array(repeating: -1, count: tokens.count) // JOIN, or any of OUTER LEFT RIGHT FULL INNER … JOIN
            var next = -1
            for index in tokens.indices.reversed() where tokens[index].kind != .comment {
                let isKeyword = tokens[index].kind == .keyword
                switch isKeyword ? words[index] : "" {
                case "JOIN":
                    throughOuter[index] = index
                    throughAny[index] = index
                case "OUTER":
                    throughOuter[index] = next >= 0 ? throughOuter[next] : -1
                    throughAny[index] = next >= 0 ? throughAny[next] : -1
                case "LEFT", "RIGHT", "FULL", "INNER":
                    throughAny[index] = next >= 0 ? throughAny[next] : -1
                default:
                    break
                }
                if words[index] == "JOIN" {
                    ends[index] = index
                } else if next >= 0 {
                    ends[index] = words[index] == "NATURAL" ? throughAny[next] : throughOuter[next]
                }
                next = index
            }
            return ends
        }

        // MARK: Run

        mutating func run() throws(SQLFormatError) -> String {
            for index in tokens.indices {
                if index & 0x1FF == 0, Task.isCancelled { throw .cancelled }
                if tokens[index].kind == .comment {
                    comment(index)
                } else {
                    token(index)
                }
                if let failure { throw failure }
            }
            flushHeldComments(final: true)
            if let failure { throw failure }
            caseChangeable.formUnion(structural)
            caseChangeable.subtract(names)
            return output
        }

        private var frame: Frame {
            get { frames[frames.count - 1] }
            set { frames[frames.count - 1] = newValue }
        }

        private var verb: String? { statementWords.first }
        private var isTrigger: Bool { verb == "CREATE" && commandObject == "TRIGGER" && frame.kind == .statement }
        private var isRule: Bool { verb == "CREATE" && commandObject == "RULE" }
        private var isRoutine: Bool { verb == "CREATE" && (commandObject == "FUNCTION" || commandObject == "PROCEDURE") }

        /// A keyword token (not used as a name) spelled `word`.
        private func isWord(_ index: Int, _ word: String) -> Bool {
            tokens[index].kind == .keyword && words[index] == word && !names.contains(index)
        }

        /// The word of a keyword token used as a keyword; "" otherwise.
        private func keywordWord(_ index: Int?) -> String {
            guard let index, tokens[index].kind == .keyword, !names.contains(index) else { return "" }
            return words[index]
        }

        private func nextSignificant(after index: Int) -> Int? {
            var next = index + 1
            while next < tokens.count {
                if tokens[next].kind != .comment { return next }
                next += 1
            }
            return nil
        }

        private func lastSignificantBefore(_ index: Int) -> Int? {
            var cursor = index - 1
            while cursor >= 0, tokens[cursor].kind == .comment { cursor -= 1 }
            return cursor >= 0 ? cursor : nil
        }

        private func isPunctuation(_ index: Int, _ text: String) -> Bool {
            (tokens[index].kind == .punctuation || tokens[index].kind == .operator) && words[index] == text
        }

        // MARK: Comments

        private mutating func comment(_ index: Int) {
            let startsLine = index == 0 || lexer.units[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]
                .contains(where: SQLFormatter.isLineBreak)
            // On the line of a held comment: stays after it.
            if !heldComments.isEmpty, !startsLine {
                heldComments.append((index, true))
                return
            }
            if startsLine, !output.isEmpty {
                heldComments.append((index, false))
                return
            }
            // Inline: stays on the current line, whatever break is pending for the next token.
            if !output.isEmpty, !atLineStart { append(" ") }
            append(lexer.text(of: tokens[index]))
            atLineStart = false
            lastWritten = index
            if isLineComment(index) {
                requestBreak(pendingBreak?.indent ?? continuationIndent, blank: pendingBreak?.blank ?? false)
            }
        }

        private func isLineComment(_ index: Int) -> Bool {
            lexer.units[tokens[index].range.lowerBound] != 0x2F // `--`; block comments start with `/`
        }

        private var continuationIndent: Int {
            statementWords.isEmpty ? frame.openIndent : frame.indent + (frame.kind == .list || frame.kind == .paren ? 0 : 1)
        }

        private mutating func flushHeldComments(final: Bool = false) {
            guard !heldComments.isEmpty else { return }
            let indent = pendingBreak?.indent ?? continuationIndent
            let blank = pendingBreak?.blank ?? false
            pendingBreak = nil
            newline(indent: indent, blank: blank)
            for (position, held) in heldComments.enumerated() {
                if position > 0 {
                    if held.sameLine { append(" ") } else { newline(indent: indent, blank: false) }
                }
                append(lexer.text(of: tokens[held.index]))
                atLineStart = false
                lastWritten = held.index
            }
            heldComments.removeAll()
            if !final { requestBreak(indent) }
        }

        // MARK: Writing

        private mutating func append(_ piece: String) {
            output += piece
            writtenUnits += piece.utf16.count
            if writtenUnits > growthLimit { failure = .tooComplex }
        }

        private mutating func requestBreak(_ indent: Int, blank: Bool = false) {
            guard !output.isEmpty else { return }
            pendingBreak = (indent, blank || (pendingBreak?.blank ?? false))
        }

        private mutating func newline(indent: Int, blank: Bool) {
            guard !output.isEmpty else { return }
            // No trailing-space trimming: the formatter never writes trailing spaces, and spaces at the end of a
            // `--` comment belong to the comment token.
            let level = min(max(0, indent), SQLFormatter.maximumIndentLevel)
            let width = SQLFormatOptions.clampedIndentWidth(options.indentWidth)
            append((blank ? lineBreak + lineBreak : lineBreak) + String(repeating: " ", count: level * width))
            lineIndent = level
            atLineStart = true
        }

        private mutating func write(_ index: Int, space: Bool) {
            let unary = isUnaryOperator(index)
            let attached = attachNext && lastWritten.map { !mustSeparate($0, index) && tokens[$0].kind != .comment } == true
            attachNext = false
            keepStringContinuation(index)
            flushHeldComments()
            if index > 0, lastWritten == index - 1, isGlued(index - 1, index) {
                pendingBreak = nil // written together in the input: stays together
            } else if let pending = pendingBreak {
                pendingBreak = nil
                newline(indent: pending.indent, blank: pending.blank)
            } else if space, !attached, !atLineStart, !output.isEmpty {
                append(" ")
            }
            append(text(of: index))
            atLineStart = false
            lastWritten = index
            lastSignificant = index
            attachNext = unary
        }

        /// Two string literals in a row: PostgreSQL concatenates them across a newline and rejects them on one line, so
        /// the newline (or its absence) between them is kept.
        private mutating func keepStringContinuation(_ index: Int) {
            guard tokens[index].kind == .string, let previous = lastSignificant, tokens[previous].kind == .string else { return }
            let gap = lexer.units[tokens[previous].range.upperBound..<tokens[index].range.lowerBound]
            if gap.contains(where: SQLFormatter.isLineBreak) {
                if pendingBreak == nil, heldComments.isEmpty, !atLineStart { requestBreak(continuationIndent) }
            } else {
                pendingBreak = nil
            }
        }

        private func text(of index: Int) -> String {
            let units = lexer.units[tokens[index].range]
            guard !names.contains(index), caseChangeable.contains(index) || structural.contains(index) else {
                return String(decoding: units, as: UTF16.self)
            }
            switch options.keywordCase {
            case .upper: return String(decoding: units.map(SQLFormatter.asciiUppercased), as: UTF16.self)
            case .lower: return String(decoding: units.map(SQLFormatter.asciiLowercased), as: UTF16.self)
            case .preserve: return String(decoding: units, as: UTF16.self)
            }
        }

        /// Tokens written together in the input stay together unless one of them may be spaced (`SQLFormatter.maySpace`):
        /// anything else (`123abc` before PostgreSQL 15, `$1::int`, `t.a`, `date'…'`, `"x"from`) could lex or parse
        /// differently with whitespace between. The equivalence check verifies the same rule.
        private func isGlued(_ previous: Int, _ index: Int) -> Bool {
            tokens[previous].range.upperBound == tokens[index].range.lowerBound
                && !SQLFormatter.maySpace(tokens[previous], in: lexer) && !SQLFormatter.maySpace(tokens[index], in: lexer)
        }

        // MARK: Tokens

        private mutating func token(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]

            if kind == .punctuation, word == ";" {
                if frames.count > 1 || atomicDepth > 0 {
                    // Inside parentheses (CREATE RULE … DO (a; b)) or a BEGIN ATOMIC body: not the end of the statement.
                    write(index, space: false)
                    if frames.count == 1 { requestBreak(frame.indent) }
                    statementWords.append("")
                    onlyQueryPrefix = false
                    return
                }
                write(index, space: false)
                endStatement()
                return
            }
            if statementWords.isEmpty {
                layout = word == "(" || (kind == .keyword && SQLFormatter.layoutStatements.contains(word))
            }
            let isName = kind == .keyword && (names.contains(index) || isNamePosition(index))
            if isName { names.insert(index) }
            trackCommandWords(index)
            // `BEGIN ATOMIC … END` of a routine (`ATOMIC` is not a keyword to the lexer); an END that closes the body.
            let beginsAtomicBody = (kind == .keyword || kind == .identifier) && word == "ATOMIC" && statementWords.last == "BEGIN"
                && statementWords.count > 1 && isRoutine
            let endsAtomicBody = !isName && kind == .keyword && word == "END" && atomicDepth > 0 && frame.cases.last?.endIndex != index
            if beginsAtomicBody || endsAtomicBody { structural.insert(index) }
            // Option lists of EXPLAIN / VACUUM / ANALYZE / …: option names and values, never user names.
            if inCommandOptions, !isName, kind == .keyword || kind == .identifier { structural.insert(index) }

            if kind == .punctuation, word == "(" || word == "[" {
                openParen(index)
            } else {
                if kind == .punctuation, word == ")" || word == "]" {
                    closeParen(index)
                } else if kind == .punctuation, word == "," {
                    comma(index)
                } else if kind == .keyword, !isName {
                    keyword(index)
                } else {
                    write(index, space: spaceBefore(index))
                }
                advanceTableName(index)
                finishListHead(index)
            }
            if beginsAtomicBody {
                atomicDepth += 1
                frame.command = nil
            }
            if endsAtomicBody { atomicDepth -= 1 }
            if kind == .keyword, !isName, ["SELECT", "WITH", "TABLE"].contains(word) {
                if word == "SELECT" { statementHasSelect = true }
                frame.pendingInsert = false // `INSERT INTO t SELECT …`: the rows come from a query
            }
            let statementWord = isName || !(kind == .keyword || kind == .identifier) ? "" : word
            statementWords.append(statementWord)
            if !SQLFormatter.queryPrefixWords.contains(statementWord) { onlyQueryPrefix = false }
        }

        private mutating func endStatement() {
            frames = [Frame(kind: .statement, indent: 0, openIndent: 0)]
            statementWords.removeAll()
            onlyQueryPrefix = true
            statementHasSelect = false
            continuesStatement = false
            listHeadEnd = nil
            joinWordsThrough = nil
            tableNameState = 0
            attachNext = false
            queryStarted = false
            inCommandWords = true
            commandObject = nil
            atomicDepth = 0
            inCommandOptions = false
            requestBreak(0, blank: true)
        }

        /// Keywords PostgreSQL accepts as names here (besides next to `.`, see `init`): as a label after AS in a select list
        /// or a FROM item (`1 AS order`, `t AS values`), and as the table name after INTO / TABLE / … (`INSERT INTO values`).
        private func isNamePosition(_ index: Int) -> Bool {
            guard let previous = lastSignificant else { return false }
            if isWord(previous, "AS"), frame.allowsClauses, [.select, .returning, .from, .join].contains(frame.clause) { return true }
            guard tableNameState == 1, !SQLKeywords.reserved.contains(words[index]) else { return false }
            return !(isProvenIfExists(index) || (words[index] == "EXISTS" && (isWord(previous, "IF") || isWord(previous, "NOT"))))
        }

        /// `IF EXISTS` / `IF NOT EXISTS` starts at `index`.
        private func isProvenIfExists(_ index: Int) -> Bool {
            guard words[index] == "IF", let next = nextSignificant(after: index) else { return false }
            if isWord(next, "EXISTS") { return true }
            return isWord(next, "NOT") && nextSignificant(after: next).map { isWord($0, "EXISTS") } == true
        }

        /// The command words at the start of a statement are keywords whatever their reservation: the first word, and for
        /// CREATE / ALTER / DROP … the words up to the object kind, then `IF [NOT] EXISTS` and `CONCURRENTLY`
        /// (`CREATE OR REPLACE VIEW`, `DROP TABLE IF EXISTS`); for VACUUM / ANALYZE / EXPLAIN / CLUSTER their option
        /// words (`VACUUM FULL VERBOSE`). The name that follows is not.
        private mutating func trackCommandWords(_ index: Int) {
            guard inCommandWords else { return }
            guard tokens[index].kind == .keyword, !names.contains(index) else {
                inCommandWords = false
                return
            }
            let word = words[index]
            guard let verb else {
                structural.insert(index)
                beginCommand(index)
                return
            }
            let previousWord = keywordWord(lastSignificant)
            var proven: Bool
            if SQLFormatter.objectCommands.contains(verb) {
                if commandObject != nil {
                    switch word {
                    case "IF": proven = isProvenIfExists(index)
                    case "NOT": proven = previousWord == "IF"
                    case "EXISTS": proven = previousWord == "IF" || previousWord == "NOT"
                    case "CONCURRENTLY": proven = true
                    case "SET", "RESET": proven = commandObject == "SYSTEM" && previousWord == "SYSTEM"
                    default: proven = false
                    }
                } else if word == "OWNED", verb == "DROP" || verb == "REASSIGN" {
                    proven = true
                } else if word == "BY", previousWord == "OWNED" {
                    proven = true
                    commandObject = "OWNED BY"
                } else if SQLFormatter.objectKinds.contains(word) {
                    proven = true
                    commandObject = word
                } else {
                    proven = SQLFormatter.commandModifiers.contains(word)
                }
            } else if ["VACUUM", "ANALYZE", "ANALYSE", "EXPLAIN", "CLUSTER"].contains(verb) {
                proven = SQLFormatter.commandPrefixOptions.contains(word)
            } else {
                proven = false
            }
            if proven {
                structural.insert(index)
            } else {
                inCommandWords = false
            }
        }

        /// A command starts in the current frame (`INSERT`, a rule's `UPDATE`, …).
        private mutating func beginCommand(_ index: Int) {
            frame.command = words[index]
            frame.pendingUpdate = words[index] == "UPDATE" ? index : nil
            frame.pendingInsert = words[index] == "INSERT"
        }

        // MARK: Parentheses, brackets, commas

        private mutating func openParen(_ index: Int) {
            let previous = lastSignificant
            // An option list right after the command word; after EXPLAIN a `(` holding a query is the query (`EXPLAIN (SELECT …)`).
            if statementWords.count == 1, ["EXPLAIN", "VACUUM", "ANALYZE", "ANALYSE", "REINDEX", "CLUSTER"].contains(statementWords[0]),
               statementWords[0] != "EXPLAIN" || !startsParenthesizedQuery(index) {
                inCommandOptions = true
            }
            let isBracket = words[index] == "["
            let afterTableName = tableNameState == 2
            let isColumnList = !isBracket && afterTableName && verb == "CREATE" && commandObject == "TABLE" && frame.kind == .statement
            let opensWindow = !isBracket && previous.map {
                (isWord($0, "OVER") && structural.contains($0)) || (isWord($0, "AS") && frame.clause == .window && frame.allowsClauses)
            } == true
            let opensIndexElements = !isBracket && afterTableName && verb == "CREATE" && commandObject == "INDEX"
            var space = isBracket ? spaceBefore(index) : spaceBeforeOpenParen(previous: previous, afterTableName: afterTableName)
            if lastWritten.map({ tokens[$0].kind == .comment }) == true { space = true }
            write(index, space: space)
            tableNameState = 0
            let nextWord = nextSignificant(after: index).map { keywordWord($0) }
            if !isBracket, layout, nextWord == "SELECT" || nextWord == "WITH" {
                frames.append(Frame(kind: .subquery, indent: lineIndent + 1, openIndent: lineIndent))
                requestBreak(lineIndent + 1)
            } else if layout, isColumnList {
                frames.append(Frame(kind: .list, indent: lineIndent + 1, openIndent: lineIndent))
                requestBreak(lineIndent + 1)
            } else {
                frames.append(Frame(kind: .paren, indent: lineIndent + 1, openIndent: lineIndent, bracket: isBracket))
            }
            frame.window = opensWindow
            frame.sortItems = opensIndexElements
            if frames.count > SQLFormatter.maximumNesting + 1 { failure = .tooComplex }
        }

        private mutating func closeParen(_ index: Int) {
            let isBracket = words[index] == "]"
            guard frames.count > 1, frame.bracket == isBracket else {
                write(index, space: false) // unbalanced or mismatched: nothing to close
                return
            }
            let closing = frames.removeLast()
            if frames.count == 1 { inCommandOptions = false }
            if closing.kind == .subquery || closing.kind == .list {
                requestBreak(closing.openIndent)
            }
            write(index, space: false)
        }

        private mutating func comma(_ index: Int) {
            write(index, space: false)
            switch frame.kind {
            case .list:
                requestBreak(frame.indent)
            case .statement, .subquery:
                if frame.clause == .with {
                    requestBreak(frame.indent)
                } else if frame.listBreak {
                    requestBreak(frame.indent + 1)
                }
            case .paren:
                break
            }
        }

        // MARK: Keywords

        private mutating func keyword(_ index: Int) {
            let word = words[index]
            let next = nextSignificant(after: index)
            let nextWord = next.map { words[$0] }

            // The rest of a multi-word join operator (`LEFT OUTER JOIN`): written as is.
            if let last = joinWordsThrough, index <= last {
                if index == last { joinWordsThrough = nil }
                structural.insert(index)
                write(index, space: true)
                return
            }
            if word == "CASE" {
                beginCase(index)
                return
            }
            if let info = frame.cases.last {
                if word == "END", info.endIndex == index {
                    if info.multiline { requestBreak(info.indent) }
                    write(index, space: spaceBefore(index))
                    frame.cases.removeLast()
                    return
                }
                if info.multiline, word == "WHEN" || word == "ELSE" {
                    requestBreak(info.indent + 1)
                    write(index, space: true)
                    return
                }
            }
            if frame.kind == .statement, verb == "CREATE", !queryStarted, startsCreateQuery(index, word: word, nextWord: nextWord) {
                queryStarted = true
            }
            let clausesActive = frame.kind == .subquery || verb != "CREATE" || queryStarted
            if layout, frame.allowsClauses, clausesActive, clause(index, word: word, next: next, nextWord: nextWord) {
                return
            }
            if layout, frame.kind == .statement, verb == "CREATE", !queryStarted, ddlClause(index, word: word, nextWord: nextWord) {
                return
            }
            if word == "BETWEEN" { frame.betweenPending = true }
            markStructural(index, word: word, next: next, nextWord: nextWord)
            write(index, space: spaceBefore(index))
        }

        /// Non-reserved keywords that are keywords only where they stand: marked when their position proves it, so a
        /// name spelled like one (`rows`, `conflict`, `following`, a CTE named `recursive`) keeps its text.
        private mutating func markStructural(_ index: Int, word: String, next: Int?, nextWord: String?) {
            let previous = lastSignificant
            let previousWord = keywordWord(previous)
            let previousIsStructural = previous.map { structural.contains($0) } ?? false
            let afterOperand = previous.map(isOperand) ?? false
            let afterCloseParen = previous.map { isPunctuation($0, ")") } ?? false
            let isCountEnd = afterOperand || previousWord == "FIRST" || previousWord == "NEXT"
            var proven = false
            switch word {
            case "BY":
                proven = previousWord == "ORDER" || previousWord == "GROUP" || (previousWord == "PARTITION" && previousIsStructural)
                if previousWord == "ORDER" { frame.sortItems = true }
            case "PARTITION":
                proven = nextWord == "BY" || (nextWord == "OF" && verb == "CREATE" && commandObject == "TABLE")
            case "OF":
                proven = previousIsStructural && (previousWord == "PARTITION"
                    || (frame.locking && (previousWord == "UPDATE" || previousWord == "SHARE"))
                    || (isTrigger && (previousWord == "UPDATE" || previousWord == "INSTEAD")))
            case "BEGIN":
                proven = nextWord == "ATOMIC" && isRoutine
            case "ROWS", "RANGE", "GROUPS":
                // Right after BY or `,` it is a sort or partition key (`ORDER BY rows`): the list needs one first.
                let startsKey = previous.map { isWord($0, "BY") || isPunctuation($0, ",") } == true
                if frame.window, !frame.windowFrame, !startsKey,
                   ["BETWEEN", "UNBOUNDED", "CURRENT", "INTERVAL"].contains(nextWord ?? "")
                    || next.map({ tokens[$0].kind == .number || tokens[$0].kind == .parameter }) == true {
                    proven = true
                    frame.windowFrame = true
                } else if word == "ROWS", frame.clause == .limit, isCountEnd {
                    proven = true // OFFSET n ROWS, FETCH FIRST n ROWS
                } else {
                    proven = isPartitionMethod(nextWord: nextWord)
                }
            case "LIST", "HASH":
                proven = isPartitionMethod(nextWord: nextWord)
            case "ROW":
                proven = (previousIsStructural && (previousWord == "CURRENT" || previousWord == "EACH")) || (frame.clause == .limit && isCountEnd)
            case "CURRENT":
                proven = frame.windowFrame && nextWord == "ROW"
            case "UNBOUNDED":
                proven = frame.windowFrame && (nextWord == "PRECEDING" || nextWord == "FOLLOWING")
            case "PRECEDING", "FOLLOWING":
                proven = frame.windowFrame && ((previousWord == "UNBOUNDED" && previousIsStructural) || afterOperand)
            case "EXCLUDE":
                proven = frame.windowFrame && ["CURRENT", "GROUP", "TIES", "NO"].contains(nextWord ?? "")
            case "TIES":
                proven = (previousWord == "EXCLUDE" && previousIsStructural) || (previousWord == "WITH" && frame.clause == .limit)
            case "OTHERS":
                proven = previousWord == "NO" && previousIsStructural
            case "NO":
                proven = (previousWord == "EXCLUDE" && previousIsStructural) || (frame.locking && previousWord == "FOR" && nextWord == "KEY")
            case "NULLS":
                proven = frame.sortItems && (nextWord == "FIRST" || nextWord == "LAST")
                    && previous.map { !isPunctuation($0, ",") && !isPunctuation($0, "(") && !isWord($0, "BY") } == true
            case "FIRST", "LAST":
                proven = (previousWord == "NULLS" && previousIsStructural) || (word == "FIRST" && previousWord == "FETCH")
            case "NEXT":
                proven = previousWord == "FETCH"
            case "BETWEEN":
                proven = afterOperand || (["ROWS", "RANGE", "GROUPS"].contains(previousWord) && previousIsStructural)
                    || (previousWord == "NOT" && previous.flatMap { lastOperand(before: $0) } != nil)
            case "EXISTS":
                proven = nextWord == "("
            case "OVER":
                // `OVER (PARTITION BY …)`, `OVER ()`, `OVER w`; a FROM item's alias `over (a, b)` is not one.
                if afterCloseParen, let next {
                    if isPunctuation(next, "(") {
                        proven = nextSignificant(after: next).map { inner in
                            isPunctuation(inner, ")") || (tokens[inner].kind == .keyword && ["PARTITION", "ORDER", "ROWS", "RANGE", "GROUPS"].contains(words[inner]))
                        } == true
                    } else {
                        proven = tokens[next].kind == .identifier || tokens[next].kind == .quotedIdentifier
                    }
                }
            case "FILTER":
                proven = afterCloseParen && next.map { isPunctuation($0, "(") && nextSignificant(after: $0).map { words[$0] == "WHERE" } == true } == true
            case "WITHIN":
                proven = afterCloseParen && nextWord == "GROUP" && next.flatMap { nextSignificant(after: $0) }.map { isPunctuation($0, "(") } == true
            case "RECURSIVE":
                // `WITH RECURSIVE r AS …`; `WITH recursive AS (…)` names a CTE `recursive`.
                proven = previousWord == "WITH" && next.map { !isPunctuation($0, "(") && !(tokens[$0].kind == .keyword && words[$0] == "AS") } == true
            case "MATERIALIZED":
                proven = nextWord == "(" && (previousWord == "AS" || previousWord == "NOT")
            case "KEY":
                proven = previousWord == "PRIMARY" || previousWord == "FOREIGN"
                    || (frame.locking && (previousWord == "NO" || previousWord == "FOR") && (nextWord == "UPDATE" || nextWord == "SHARE"))
            case "CONFLICT":
                proven = previousWord == "ON" && frame.command == "INSERT" && isConflictTarget(after: index)
            case "MATCHED":
                proven = verb == "MERGE" && (previousWord == "WHEN"
                    || (previousWord == "NOT" && previous.flatMap { lastSignificantBefore($0) }.map { keywordWord($0) == "WHEN" } == true))
            case "NOTHING":
                proven = previousWord == "DO" || ((previousWord == "ALSO" || previousWord == "INSTEAD") && previousIsStructural)
            case "INSERT", "UPDATE", "DELETE", "TRUNCATE":
                proven = markCommand(index, word: word, previousWord: previousWord, previousIsStructural: previousIsStructural, nextWord: nextWord)
            case "BEFORE", "AFTER":
                proven = isTrigger && ["INSERT", "UPDATE", "DELETE", "TRUNCATE"].contains(nextWord ?? "")
            case "INSTEAD":
                proven = previousWord == "DO" || (isTrigger && nextWord == "OF")
            case "ALSO":
                proven = previousWord == "DO"
            case "EACH":
                proven = isTrigger && previousWord == "FOR" && (nextWord == "ROW" || nextWord == "STATEMENT")
            case "STATEMENT":
                proven = previousWord == "EACH" && previousIsStructural
            case "EXECUTE":
                proven = isTrigger && (nextWord == "FUNCTION" || nextWord == "PROCEDURE")
            case "FUNCTION", "PROCEDURE":
                proven = previousWord == "EXECUTE" && previousIsStructural
            case "SHARE":
                proven = frame.locking && (previousWord == "FOR" || previousWord == "KEY")
            case "SKIP":
                proven = frame.locking && nextWord == "LOCKED"
            case "LOCKED":
                proven = previousWord == "SKIP" && previousIsStructural
            case "NOWAIT":
                proven = frame.locking
            case "SET":
                proven = isUpdateSet()
                if proven { frame.pendingUpdate = nil }
            case "VALUES":
                // A partition bound (`FOR VALUES`), `DEFAULT VALUES` of an INSERT, or rows (`INSERT INTO t VALUES (…)` in a
                // rule action or CTE, a MERGE's `INSERT (…) VALUES (…)`, `(VALUES (…))`).
                proven = (previousWord == "FOR" && verb == "CREATE" && commandObject == "TABLE")
                    || (previousWord == "DEFAULT" && frame.pendingInsert)
                    || isValuesQuery(previous: previous, nextWord: nextWord)
                if proven { frame.pendingInsert = false }
            case "ROLLUP", "CUBE":
                proven = nextWord == "(" && frame.allowsClauses && frame.clause == .groupBy
                    && (previousWord == "BY" || previous.map { isPunctuation($0, ",") } == true)
            case "GROUPING":
                proven = nextWord == "SETS" && frame.allowsClauses && frame.clause == .groupBy
            case "SETS":
                proven = previousWord == "GROUPING" && previousIsStructural
            case "RETURNS":
                proven = isRoutine && frame.kind == .statement && !queryStarted
            case "LANGUAGE":
                proven = frame.kind == .statement && ((isRoutine && !queryStarted) || verb == "DO")
            case "AUTHORIZATION":
                proven = (verb == "CREATE" && commandObject == "SCHEMA") || (previousWord == "SESSION" && previousIsStructural)
            case "SESSION":
                proven = (verb == "SET" || verb == "RESET") && statementWords.count == 1 && nextWord == "AUTHORIZATION"
            case "IS", "ISNULL", "NOTNULL", "OVERLAPS", "TABLESAMPLE":
                proven = afterOperand
            case "LIKE", "ILIKE", "SIMILAR":
                proven = afterOperand || (previousWord == "NOT" && previous.flatMap { lastOperand(before: $0) } != nil)
                    // `CREATE TABLE t (LIKE u …)`: a column-list item starting with LIKE ('T' words cannot name columns).
                    || (word == "LIKE" && frame.kind == .list && previous.map { isPunctuation($0, "(") || isPunctuation($0, ",") } == true)
            case "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER":
                // A join operator after a FROM item (`left(…)` and `join(…)` may be functions).
                proven = joinEnd(from: index) != nil
                    && (afterOperand || (SQLFormatter.joinWords.contains(previousWord) && previousIsStructural))
            case "INTERVAL", "TIMESTAMP", "TIME":
                // A typed literal: `INTERVAL '1 day'`.
                proven = next.map { tokens[$0].kind == .string } == true
            default:
                proven = false
            }
            if proven { structural.insert(index) }
        }

        /// The `(` at `open` holds a query: SELECT / WITH / VALUES / TABLE (reserved, so never an option name) or another `(`.
        private func startsParenthesizedQuery(_ open: Int) -> Bool {
            guard let inner = nextSignificant(after: open) else { return false }
            return isPunctuation(inner, "(") || ["SELECT", "WITH", "VALUES", "TABLE"].contains(keywordWord(inner))
        }

        /// The `(` at `open` holds a statement: a CTE body (`AS (`, `AS [NOT] MATERIALIZED (`), a rule action (`DO [ALSO |
        /// INSTEAD] (`) or COPY's query. Not a column list (`CREATE TABLE t (update int)`) or index elements.
        private func opensStatementBody(_ open: Int) -> Bool {
            ["AS", "MATERIALIZED", "DO", "ALSO", "INSTEAD", "COPY"].contains(keywordWord(lastSignificantBefore(open)))
        }

        /// A query starts here: at the start of the statement, or right after `(`.
        private func startsQuery(after previous: Int?) -> Bool {
            (statementWords.isEmpty && !continuesStatement) || previous.map { isPunctuation($0, "(") } == true
        }

        /// `previous` is a set operator, with its `ALL` / `DISTINCT` (`UNION ALL`): a query follows. (`SELECT DISTINCT values`
        /// is a column.)
        private func isSetOperator(_ previous: Int?) -> Bool {
            guard let previous else { return false }
            let word = keywordWord(previous)
            if SQLFormatter.setOperators.contains(word) { return true }
            return (word == "ALL" || word == "DISTINCT") && SQLFormatter.setOperators.contains(keywordWord(lastSignificantBefore(previous)))
        }

        /// `VALUES` followed by its rows `(…)` where a query or an INSERT's rows may stand. Elsewhere `values` is a name:
        /// a column (`SELECT DISTINCT values`), or an alias with a column list (`FROM (SELECT 1) values (a)`).
        private func isValuesQuery(previous: Int?, nextWord: String?) -> Bool {
            guard nextWord == "(" else { return false }
            if frame.pendingInsert { return keywordWord(previous) != "DEFAULT" }
            return startsQuery(after: previous) || isSetOperator(previous)
                || (verb == "CREATE" && frame.kind == .statement && keywordWord(previous) == "AS")
        }

        /// The query of a CREATE statement starts at `index`: after AS (`CREATE VIEW v AS SELECT`, `CREATE TABLE t AS VALUES`),
        /// a rule's `DO [ALSO | INSTEAD]`, or in a BEGIN ATOMIC body. Not a policy's `FOR SELECT` or a rule's `ON SELECT`.
        private func startsCreateQuery(_ index: Int, word: String, nextWord: String?) -> Bool {
            switch word {
            case "SELECT", "WITH", "TABLE": break
            case "VALUES": guard nextWord == "(" else { return false }
            default: return false
            }
            guard let previous = lastSignificant else { return false }
            switch keywordWord(previous) {
            case "AS", "DO": return true
            case "ALSO", "INSTEAD": return structural.contains(previous)
            default: break
            }
            return atomicDepth > 0 && (isPunctuation(previous, ";") || (words[previous] == "ATOMIC" && structural.contains(previous)))
        }

        /// `RANGE` / `LIST` / `HASH` right after `PARTITION BY` of a CREATE TABLE.
        private func isPartitionMethod(nextWord: String?) -> Bool {
            verb == "CREATE" && commandObject == "TABLE" && frame.kind == .statement && nextWord == "("
                && statementWords.suffix(2) == ["PARTITION", "BY"]
        }

        /// After `ON CONFLICT`: `DO …`, `ON CONSTRAINT …`, or `(target) [WHERE …] DO …`.
        private func isConflictTarget(after index: Int) -> Bool {
            guard let next = nextSignificant(after: index) else { return false }
            if isWord(next, "DO") || isWord(next, "ON") { return true }
            guard isPunctuation(next, "("), closers[next] >= 0, let after = nextSignificant(after: closers[next]) else { return false }
            return isWord(after, "DO") || isWord(after, "WHERE")
        }

        /// INSERT / UPDATE / DELETE / TRUNCATE that are keywords here: a locking strength, a trigger's or rule's event, or
        /// a command inside a statement (a rule action, a data-modifying CTE, a BEGIN ATOMIC body, `ON CONFLICT DO UPDATE`).
        private mutating func markCommand(_ index: Int, word: String, previousWord: String, previousIsStructural: Bool,
                                          nextWord: String?) -> Bool {
            if word == "UPDATE", frame.locking, previousWord == "FOR" || previousWord == "KEY" { return true }
            if isTrigger, ["BEFORE", "AFTER", "OR"].contains(previousWord) || (previousWord == "OF" && previousIsStructural) { return true }
            if isRule, frame.kind == .statement, previousWord == "ON", nextWord == "TO", word != "TRUNCATE" { return true }
            if verb == "MERGE", frame.kind == .statement, previousWord == "THEN" {
                // A MERGE action: `THEN UPDATE SET`, `THEN DELETE`, `THEN INSERT [(…)] VALUES | DEFAULT VALUES`.
                switch word {
                case "UPDATE":
                    guard nextWord == "SET" else { return false }
                    frame.pendingUpdate = index
                    return true
                case "DELETE": return nextWord == nil || nextWord == "WHEN" || nextWord == ";"
                case "INSERT":
                    guard nextWord == "(" || ["VALUES", "DEFAULT", "OVERRIDING"].contains(nextWord ?? "") else { return false }
                    frame.pendingInsert = true
                    return true
                default: return false
                }
            }
            guard word != "TRUNCATE", let previous = lastSignificant else { return false }
            let startsCommand = previousWord == "DO" || ((previousWord == "ALSO" || previousWord == "INSTEAD") && previousIsStructural)
                || (isWord(previous, "ATOMIC") || (tokens[previous].kind == .identifier && words[previous] == "ATOMIC")) && structural.contains(previous)
                || (isPunctuation(previous, "(") && opensStatementBody(previous)) || isPunctuation(previous, ";")
            let afterWithList = frame.clause == .with && isPunctuation(previous, ")")
            guard startsCommand || afterWithList else { return false }
            if word == "UPDATE", previousWord == "DO", frame.command == "INSERT" {
                // ON CONFLICT DO UPDATE SET: the INSERT's own action.
                guard nextWord == "SET" else { return false }
                frame.pendingUpdate = index
                return true
            }
            let proven: Bool
            switch word {
            case "INSERT": proven = nextWord == "INTO"
            case "DELETE": proven = nextWord == "FROM"
            default:
                proven = nextSignificant(after: index).map { next in
                    let kind = tokens[next].kind
                    return kind == .identifier || kind == .quotedIdentifier || isWord(next, "ONLY")
                        || (kind == .keyword && !SQLKeywords.reserved.contains(words[next]))
                } == true
            }
            if proven {
                beginCommand(index)
                // The statement after its WITH list starts a line, like a SELECT there.
                if afterWithList, layout, frame.allowsClauses {
                    requestBreak(frame.indent)
                    setClause(.other)
                }
            }
            return proven
        }

        /// The SET of an UPDATE in this frame: after its table name (`UPDATE set SET …` names a table `set`), or right after
        /// `DO UPDATE` of ON CONFLICT.
        private func isUpdateSet() -> Bool {
            guard let update = frame.pendingUpdate, let previous = lastSignificant else { return false }
            if previous == update { return frame.command == "INSERT" || frame.command == "MERGE" }
            return !isWord(previous, "ONLY") && !isWord(previous, "AS") && !isPunctuation(previous, ".")
        }

        /// A token that ends an operand: a name, literal, parameter, `)` or `]`.
        private func isOperand(_ index: Int) -> Bool {
            if names.contains(index) { return true }
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier, .number, .string, .parameter: return true
            case .punctuation: return words[index] == ")" || words[index] == "]"
            case .keyword: return !SQLKeywords.reserved.contains(words[index]) || SQLFormatter.operandKeywords.contains(words[index])
            default: return false
            }
        }

        private func lastOperand(before index: Int) -> Int? {
            lastSignificantBefore(index).flatMap { isOperand($0) ? $0 : nil }
        }

        /// Clause layout inside a statement or subquery. Returns `true` when the token was written.
        private mutating func clause(_ index: Int, word: String, next: Int?, nextWord: String?) -> Bool {
            let isFirstQueryWord = onlyQueryPrefix && !continuesStatement
            let breakIndent = frame.indent
            let previous = lastSignificant

            // AND / OR conditions; the AND of BETWEEN stays.
            if word == "AND" || word == "OR" {
                if word == "AND", frame.betweenPending {
                    frame.betweenPending = false
                    return false
                }
                guard frame.cases.isEmpty, frame.clause == .whereLike || frame.clause == .on else { return false }
                requestBreak(breakIndent + 1)
                write(index, space: true)
                return true
            }
            // Joins after a FROM item: [NATURAL] [LEFT|RIGHT|FULL] [OUTER] JOIN, INNER JOIN, CROSS JOIN.
            if SQLFormatter.joinWords.contains(word), word != "OUTER", previous.map(isOperand) == true, let end = joinEnd(from: index) {
                requestBreak(breakIndent)
                structural.insert(index)
                write(index, space: true)
                if end > index { joinWordsThrough = end }
                setClause(.join)
                return true
            }
            if word == "ON", frame.clause == .join {
                requestBreak(breakIndent + 1)
                write(index, space: true)
                setClause(.on)
                return true
            }
            if word == "ON", nextWord == "CONFLICT", frame.command == "INSERT", let next, isConflictTarget(after: next) {
                requestBreak(breakIndent)
                write(index, space: true)
                setClause(.other)
                return true
            }
            // Locking clause: FOR UPDATE / NO KEY UPDATE / SHARE / KEY SHARE.
            if word == "FOR", ["UPDATE", "SHARE", "NO", "KEY"].contains(nextWord ?? ""), statementHasSelect {
                requestBreak(breakIndent)
                write(index, space: true)
                setClause(.other)
                frame.locking = true
                return true
            }
            if word == "WITH" {
                // A WITH that starts the query (statement or subquery); others (`WITH ORDINALITY`, …) stay inline.
                let startsQuery = isFirstQueryWord || (previous.map { isPunctuation($0, "(") } ?? false)
                guard startsQuery else { return false }
                write(index, space: true)
                setClause(.with)
                return true
            }

            guard SQLFormatter.clauseWords.contains(word) else { return false }
            switch word {
            case "SET":
                // An UPDATE statement's SET clause (ON CONFLICT's `DO UPDATE SET` stays inline).
                guard frame.command == "UPDATE", isUpdateSet() else { return false }
                structural.insert(index)
                frame.pendingUpdate = nil
            case "VALUES":
                guard isValuesQuery(previous: previous, nextWord: nextWord) else { return false }
                structural.insert(index)
                frame.pendingInsert = false
            case "GROUP", "ORDER":
                guard nextWord == "BY" else { return false }
            case "FETCH":
                guard nextWord == "FIRST" || nextWord == "NEXT", statementHasSelect || frame.kind == .subquery else { return false }
            case "FROM":
                // `IS [NOT] DISTINCT FROM` is an operator.
                if keywordWord(previous) == "DISTINCT", let distinct = previous,
                   ["IS", "NOT"].contains(keywordWord(lastSignificantBefore(distinct))) {
                    return false
                }
                if statementWords.last == "DELETE" {
                    write(index, space: true)
                    setClause(.from)
                    return true
                }
            default:
                break
            }
            if !(isFirstQueryWord && (word == "SELECT" || word == "VALUES" || word == "SET")) {
                requestBreak(breakIndent)
            }
            write(index, space: true)
            switch word {
            case "SELECT":
                startList(.select, headEnd: selectHeadEnd(index))
            case "GROUP": startList(.groupBy, headEnd: next ?? index)
            case "ORDER": startList(.orderBy, headEnd: next ?? index)
            case "SET": startList(.set, headEnd: index)
            case "VALUES": startList(.values, headEnd: index)
            case "RETURNING": startList(.returning, headEnd: index)
            case "FROM": setClause(.from)
            case "WHERE", "HAVING": setClause(.whereLike)
            case "LIMIT", "OFFSET", "FETCH": setClause(.limit)
            case "WINDOW": setClause(.window)
            default: setClause(.other)
            }
            return true
        }

        /// The last token of `SELECT [ALL | DISTINCT [ON (…)]]`.
        private func selectHeadEnd(_ index: Int) -> Int {
            guard let next = nextSignificant(after: index), isWord(next, "DISTINCT") || isWord(next, "ALL") else { return index }
            guard isWord(next, "DISTINCT"), let on = nextSignificant(after: next), isWord(on, "ON"),
                  let open = nextSignificant(after: on), isPunctuation(open, "("), closers[open] >= 0 else { return next }
            return closers[open]
        }

        /// CREATE TABLE clauses after the column list at statement level. Returns `true` when the token was written.
        private mutating func ddlClause(_ index: Int, word: String, nextWord: String?) -> Bool {
            guard commandObject == "TABLE" else { return false }
            let starts = (word == "PARTITION" && nextWord == "BY") || (word == "INHERITS" && nextWord == "(")
            guard starts, lastSignificant.map({ isPunctuation($0, ")") }) == true else { return false }
            structural.insert(index)
            requestBreak(frame.indent)
            write(index, space: true)
            setClause(.ddl)
            return true
        }

        /// Index of the `JOIN` that completes a join operator starting at `index`, or `nil`.
        private func joinEnd(from index: Int) -> Int? {
            joinEnds[index] >= 0 ? joinEnds[index] : nil
        }

        private mutating func setClause(_ clause: Frame.Clause) {
            frame.clause = clause
            frame.listBreak = false
            frame.betweenPending = false
            frame.sortItems = false
            frame.locking = false
            listHeadEnd = nil
        }

        private mutating func startList(_ clause: Frame.Clause, headEnd: Int) {
            setClause(clause)
            frame.listBreak = topLevelCommas(after: headEnd) > 0
            listHeadEnd = headEnd
            finishListHead(index: headEnd, written: lastWritten)
        }

        /// After the last token of a list clause head (SELECT [DISTINCT [ON (…)]], GROUP BY, …): break before the first item.
        private mutating func finishListHead(_ index: Int) {
            finishListHead(index: index, written: index)
        }

        private mutating func finishListHead(index: Int, written: Int?) {
            guard let head = listHeadEnd, head == index, written == index, frame.allowsClauses else { return }
            listHeadEnd = nil
            if frame.listBreak { requestBreak(frame.indent + 1) }
        }

        /// Commas at this nesting level until the clause ends (nested brackets are skipped whole).
        private func topLevelCommas(after index: Int) -> Int {
            var commas = 0
            var cursor = index + 1
            var previous: Int? = index
            while cursor < tokens.count {
                let token = tokens[cursor]
                let word = words[cursor]
                if token.kind == .comment {
                    cursor += 1
                    continue
                }
                if token.kind == .punctuation {
                    switch word {
                    case "(", "[":
                        guard closers[cursor] >= 0 else { return commas } // unbalanced: the rest is inside
                        previous = closers[cursor]
                        cursor = closers[cursor] + 1
                        continue
                    case ")", "]", ";":
                        return commas
                    case ",":
                        commas += 1
                    default:
                        break
                    }
                } else if token.kind == .keyword, SQLFormatter.listEndWords.contains(word), // "" next to `.` (`t.from`)
                          // `left(…)` is a function; a join word ends the clause only as part of a join operator.
                          !SQLFormatter.joinWords.contains(word) || joinEnd(from: cursor) != nil,
                          // A keyword after AS is a label (`1 AS order`).
                          previous.map({ !(tokens[$0].kind == .keyword && words[$0] == "AS") }) ?? true {
                    return commas
                }
                previous = cursor
                cursor += 1
            }
            return commas
        }

        // MARK: CASE

        private mutating func beginCase(_ index: Int) {
            let endIndex = caseEnds[index] >= 0 ? caseEnds[index] : nil
            let multiline = layout && frame.kind != .paren && endIndex != nil && caseBranches[index] >= 2
            write(index, space: spaceBefore(index))
            frame.cases.append(CaseInfo(multiline: multiline, indent: lineIndent, endIndex: endIndex))
        }

        // MARK: Spacing

        /// Tracks whether the tokens after INTO / TABLE / VIEW / REFERENCES (and ON of CREATE INDEX) are a (qualified)
        /// table name, so `t (a, b)` keeps its space.
        private mutating func advanceTableName(_ index: Int) {
            let kind = tokens[index].kind
            let word = words[index]
            let isKeyword = kind == .keyword && !names.contains(index)
            // `CREATE INDEX i ON t USING btree (a)`: the table and the access method are names before `(`.
            let indexName = (word == "ON" || word == "USING") && verb == "CREATE" && commandObject == "INDEX"
            if isKeyword, word == "INTO" || word == "TABLE" || word == "VIEW" || word == "REFERENCES" || indexName {
                tableNameState = 1
                return
            }
            switch tableNameState {
            case 1:
                if isKeyword, word == "NOT" || word == "EXISTS" || word == "ONLY" || (word == "IF" && structural.contains(index)) { return }
                let isName = kind == .identifier || kind == .quotedIdentifier || names.contains(index)
                    || (isKeyword && !SQLKeywords.reserved.contains(word))
                tableNameState = isName ? 2 : 0
            case 2:
                tableNameState = isPunctuation(index, ".") ? 1 : 0
            default:
                break
            }
        }

        private func spaceBeforeOpenParen(previous: Int?, afterTableName: Bool) -> Bool {
            guard let previous else { return false }
            if afterTableName { return true }
            switch tokens[previous].kind {
            case .identifier, .quotedIdentifier: return false
            case .keyword:
                let word = words[previous]
                if names.contains(previous) { return false }
                // A keyword its position proves (`EXISTS (`, `OVER (`, `GROUP BY CUBE (`) is followed by a space; a word
                // that may name a function or type and is not proven a keyword here is written like a call (`left(…)`,
                // `join(…)`, `cube(…)`).
                if structural.contains(previous) { return true }
                return !SQLFormatter.callLikeKeywords.contains(word) && !SQLFormatter.typeFunctionNameKeywords.contains(word)
            case .punctuation: return words[previous] == "," || words[previous] == ")" || words[previous] == "]"
            case .operator: return words[previous] != "::"
            default: return true
            }
        }

        private func spaceBefore(_ index: Int) -> Bool {
            guard let previous = lastWritten else { return false }
            let current = tokens[index]
            let text = words[index]
            let prev = tokens[previous]
            let prevText = words[previous]

            if prev.kind == .comment { return true }
            switch current.kind {
            case .punctuation where text == ")" || text == "," || text == ";" || text == "]":
                return false
            case .punctuation where text == ".":
                return mustSeparate(previous, index) || !isNameLike(previous)
            case .punctuation where text == "[":
                // After a keyword the input decides (`ARRAY[1]`, `ARRAY [1]`); after a name or `)` / `]` a subscript; after
                // `[` a nested array (`ARRAY[[1, 2], [3, 4]]`).
                if prev.kind == .keyword { return prev.range.upperBound != current.range.lowerBound }
                if prev.kind == .punctuation, prevText == "[" || prevText == "(" { return false }
                return !isNameLike(previous)
            case .operator where text == "::" || text == ":":
                return mustSeparate(previous, index)
            default:
                break
            }
            if prev.kind == .punctuation, prevText == "(" || prevText == "." || prevText == "[" { return mustSeparate(previous, index) }
            if prev.kind == .operator, prevText == "::" || prevText == ":" { return mustSeparate(previous, index) }
            return true
        }

        private func isNameLike(_ index: Int) -> Bool {
            switch tokens[index].kind {
            case .identifier, .quotedIdentifier, .keyword, .parameter: true
            case .punctuation: words[index] == ")" || words[index] == "]"
            default: false
            }
        }

        /// A `-` / `+` sign (not a binary operator), judged from the token before it.
        private func isUnaryOperator(_ index: Int) -> Bool {
            guard tokens[index].kind == .operator, words[index] == "-" || words[index] == "+" else { return false }
            guard let previous = lastSignificant else { return true }
            let word = words[previous]
            switch tokens[previous].kind {
            case .operator: return true
            case .punctuation: return word == "(" || word == "," || word == "["
            case .keyword:
                return !names.contains(previous) && SQLKeywords.reserved.contains(word) && !SQLFormatter.operandKeywords.contains(word)
            default: return false
            }
        }

        /// Whether writing `index` directly after `previous` would lex differently.
        private func mustSeparate(_ previous: Int, _ index: Int) -> Bool {
            let prev = tokens[previous]
            let current = tokens[index]
            let wordLike: Set<SQLToken.Kind> = [.identifier, .keyword, .number, .parameter, .quotedIdentifier]
            if wordLike.contains(prev.kind), wordLike.contains(current.kind) { return true }
            // `'a''b'` is one string, `E'x'` / `a$$x$$` one token.
            if prev.kind == .string, current.kind == .string || current.kind == .identifier || current.kind == .keyword { return true }
            if prev.kind == .identifier || prev.kind == .keyword, current.kind == .string { return true }
            if prev.kind == .number, words[index] == "." { return true }
            if words[previous] == ".", current.kind == .number { return true }
            if prev.kind == .parameter, words[index] == "." { return true }
            if prev.kind == .operator, current.kind == .operator {
                // Operator characters run together into one operator; `:` then `:` or `=` is `::` / `:=`.
                let last = lexer.units[prev.range.upperBound - 1]
                let first = lexer.units[current.range.lowerBound]
                if SQLLexer.isOperatorCharacter(last), SQLLexer.isOperatorCharacter(first) { return true }
                if last == 0x3A, first == 0x3A || first == 0x3D { return true }
            }
            return false
        }
    }
}
