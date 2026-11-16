import Foundation
import PostgresKit
import PostgresWire

/// A PostgreSQL statement error: the ErrorResponse fields the editor needs (recorded from PostgreSQL 17).
///
/// `position` (`P`) is a 1-based **code-point** index into the text that was sent — for a simple-protocol script, the
/// whole script. Errors raised inside a function or `DO` block have no `P`; they carry the internal query (`q`) and
/// position (`p`) and a context (`W`, e.g. `PL/pgSQL function inline_code_block line 3 at RAISE`). Errors such as
/// `table "x" does not exist` (DROP) carry neither: the object they name is searched instead.
public struct SQLServerError: Sendable, Equatable {
    public let message: String
    public let sqlState: String?
    public let position: Int?
    public let internalQuery: String?
    public let internalPosition: Int?
    public let context: String?
    public let detail: String?
    public let hint: String?
    public let schemaName: String?
    public let tableName: String?
    public let columnName: String?
    /// `message` for display, at most `summaryLimit` characters (an unterminated string's message echoes the rest of
    /// the script).
    public let summary: String
    /// Objects the error names, most specific first (`relation "shop.t"` → `["shop", "t"]`). Names are as PostgreSQL
    /// stores them: unquoted identifiers are already folded to lower case.
    public let names: [[String]]

    public static let summaryLimit = 500
    /// Longest hint or detail repeated in the one-line diagnostic message.
    static let fieldLimit = 300

    public init(message: String, sqlState: String? = nil, position: Int? = nil, internalQuery: String? = nil,
                internalPosition: Int? = nil, context: String? = nil, detail: String? = nil, hint: String? = nil,
                schemaName: String? = nil, tableName: String? = nil, columnName: String? = nil) {
        self.message = message
        self.sqlState = sqlState
        self.position = position
        self.internalQuery = internalQuery
        self.internalPosition = internalPosition
        self.context = context
        self.detail = detail
        self.hint = hint
        self.schemaName = schemaName
        self.tableName = tableName
        self.columnName = columnName
        summary = Self.shortened(message, to: Self.summaryLimit)
        names = Self.names(in: String(message.prefix(4_096)), schema: schemaName, table: tableName, column: columnName)
    }

    public init(fields: ServerMessageFields) {
        self.init(message: fields.message.isEmpty ? "Server error \(fields.sqlState ?? "")" : fields.message,
                  sqlState: fields.sqlState, position: fields.position, internalQuery: fields.internalQuery,
                  internalPosition: fields.internalPosition, context: fields.whereContext, detail: fields.detail, hint: fields.hint,
                  schemaName: fields.schemaName, tableName: fields.tableName, columnName: fields.columnName)
    }

    /// Any failure: the server's fields when it has some, otherwise its message.
    public init(_ error: any Error) {
        if let error = error as? PostgresError {
            if let fields = error.fields {
                self.init(fields: fields)
            } else {
                self.init(message: error.message)
            }
        } else {
            self.init(message: error.localizedDescription)
        }
    }

    // MARK: Presentation

    /// The kind, from the SQLSTATE class.
    public var kindLabel: String {
        guard let sqlState, sqlState.utf8.count == 5 else { return "Error" }
        switch sqlState {
        case "42601": return "Syntax error"
        case "42501": return "Permission denied"
        default: break
        }
        switch sqlState.prefix(2) {
        case "22": return "Data error"
        case "23": return "Integrity violation"
        case "25": return "Transaction state error"
        case "40": return "Transaction rolled back"
        case "53": return "Insufficient resources"
        case "57": return "Statement interrupted"
        case "P0": return "PL/pgSQL error"
        default: return "Error"
        }
    }

    /// PostgreSQL's condition name for common SQLSTATEs (`42703` → `undefined_column`).
    public var conditionName: String? { sqlState.flatMap { Self.conditionNames[$0] } }

    /// The kind, with an **editor** position when one is known. The server's own position is relative to the text sent
    /// (which may include an `EXPLAIN` prefix or a whole script), so it is never shown here.
    public func title(at position: SQLTextPosition?) -> String {
        guard let position else { return kindLabel }
        return "\(kindLabel) at line \(position.line), column \(position.column)"
    }

    /// One line for the editor: the message, then the hint and the detail (each shortened).
    public var diagnosticMessage: String {
        var text = summary
        if let hint, !hint.isEmpty { text += " — HINT: " + Self.shortened(hint, to: Self.fieldLimit) }
        if let detail, !detail.isEmpty { text += " — DETAIL: " + Self.shortened(detail, to: Self.fieldLimit) }
        return text
    }

    /// A server-supplied text (detail, context, internal query) bounded for display; Copy keeps the whole error.
    public static func shortenedForDisplay(_ text: String) -> String { shortened(text, to: 2_000) }

    static func shortened(_ text: String, to limit: Int) -> String {
        let head = text.prefix(limit + 1)
        guard head.count > limit else { return String(head) }
        return String(head.prefix(limit)) + "…"
    }

    static let conditionNames: [String: String] = [
        "42601": "syntax_error", "42501": "insufficient_privilege", "42703": "undefined_column", "42P01": "undefined_table",
        "42883": "undefined_function", "42704": "undefined_object", "42702": "ambiguous_column", "42725": "ambiguous_function",
        "42P07": "duplicate_table", "42701": "duplicate_column", "42710": "duplicate_object", "42723": "duplicate_function",
        "42P06": "duplicate_schema", "42804": "datatype_mismatch", "42803": "grouping_error", "42P18": "indeterminate_datatype",
        "42P02": "undefined_parameter", "42P10": "invalid_column_reference", "42809": "wrong_object_type", "42846": "cannot_coerce",
        "42830": "invalid_foreign_key", "42939": "reserved_name", "3F000": "invalid_schema_name", "3D000": "invalid_catalog_name",
        "22012": "division_by_zero", "22P02": "invalid_text_representation", "22001": "string_data_right_truncation",
        "22003": "numeric_value_out_of_range", "22007": "invalid_datetime_format", "22008": "datetime_field_overflow",
        "22023": "invalid_parameter_value", "22004": "null_value_not_allowed", "21000": "cardinality_violation",
        "23502": "not_null_violation", "23503": "foreign_key_violation", "23505": "unique_violation", "23514": "check_violation",
        "23P01": "exclusion_violation", "25P02": "in_failed_sql_transaction", "25006": "read_only_sql_transaction",
        "25001": "active_sql_transaction", "40001": "serialization_failure", "40P01": "deadlock_detected",
        "55P03": "lock_not_available", "57014": "query_canceled", "0A000": "feature_not_supported",
        "2BP01": "dependent_objects_still_exist", "P0001": "raise_exception", "P0002": "no_data_found", "P0003": "too_many_rows",
        "53100": "disk_full", "53200": "out_of_memory", "54001": "statement_too_complex", "XX000": "internal_error",
    ]

    // MARK: Names

    static func names(in message: String, schema: String?, table: String?, column: String?) -> [[String]] {
        // (where the name appears in the message, the name as written there)
        var found: [(String.Index, Substring)] = []
        let kinds = /(?:column reference|column|relation|table|view|materialized view|foreign table|index|sequence|schema|type|domain|database|role|extension|trigger|constraint|collation|cursor|prepared statement|function|procedure) "([^"]+)"/
        for match in message.matches(of: kinds) { found.append((match.range.lowerBound, match.output.1)) }
        // `column t.nme does not exist`: a qualified reference is printed unquoted.
        for match in message.matches(of: /column ([^\s"]+) does not exist/) { found.append((match.range.lowerBound, match.output.1)) }
        // `function shop.f(integer) does not exist`.
        for match in message.matches(of: /(?:function|procedure|aggregate) ([^\s("]+|"[^"]+")\(/) { found.append((match.range.lowerBound, match.output.1)) }
        let permission = /permission denied for (?:table|schema|sequence|view|materialized view|foreign table|function|procedure|database|type|language) ([^\s]+)/
        for match in message.matches(of: permission) { found.append((match.range.lowerBound, match.output.1)) }
        var names: [[String]] = []
        for (_, raw) in found.sorted(by: { $0.0 < $1.0 }) {
            let segments = nameSegments(String(raw))
            if !segments.isEmpty, !names.contains(segments) { names.append(segments) }
        }
        // Structured fields (also when messages are localized): the column, then the table with its schema.
        if let column, !column.isEmpty, !names.contains([column]) { names.append([column]) }
        if let table, !table.isEmpty {
            let qualified = schema.map { $0.isEmpty ? [table] : [$0, table] } ?? [table]
            if let index = names.firstIndex(of: [table]) {
                if !names.contains(qualified) { names[index] = qualified }
            } else if !names.contains(qualified) {
                names.append(qualified)
            }
        }
        return names
    }

    /// `shop.t` → `["shop", "t"]`; `"My.T".x` → `["My.T", "x"]` (doubled quotes unescaped).
    static func nameSegments(_ raw: String) -> [String] {
        let characters = Array(raw)
        var segments: [String] = []
        var current = ""
        var quoted = false
        var index = 0
        func flush() {
            if !current.isEmpty { segments.append(current) }
            current = ""
        }
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        current.append("\"")
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "." {
                flush()
            } else {
                current.append(character)
            }
            index += 1
        }
        flush()
        return segments
    }
}

/// How the text the server executed relates to the statement in the editor: the app may prepend
/// (`EXPLAIN (FORMAT JSON) `) and insert (` LIMIT n`). Offsets are UTF-16.
public struct SQLExecutedTextMapping: Sendable, Equatable {
    public var prefixLength: Int
    /// Range of inserted text, in executed coordinates.
    public var insertion: Range<Int>?

    public static let identity = SQLExecutedTextMapping()

    public init(prefixLength: Int = 0, insertion: Range<Int>? = nil) {
        self.prefixLength = max(0, prefixLength)
        self.insertion = insertion
    }

    /// Source offset for an executed offset. Positions inside the insertion map to its start; positions inside the
    /// prefix map to 0. Never negative.
    public func sourceOffset(forExecuted offset: Int) -> Int {
        var value = max(0, offset)
        if let insertion {
            if value >= insertion.upperBound {
                value -= insertion.count
            } else if value > insertion.lowerBound {
                value = insertion.lowerBound
            }
        }
        return max(0, value - prefixLength)
    }
}

/// Finds the text a PostgreSQL error refers to inside the statement (or script) that failed.
public enum SQLErrorLocator {
    /// UTF-16 offset of the character at `position` (1-based, code points), clamped to the statement; nil for
    /// non-positive positions.
    public static func utf16Offset(in statement: String, position: Int) -> Int? {
        utf16Offset(ofCharacter: position, in: Array(statement.utf16))
    }

    /// The range (UTF-16, in `source`) to mark for `error`. A position is resolved in `executed` (what the server saw;
    /// `source` when nil) and mapped back with `mapping`, then:
    /// - an unterminated string, quoted identifier, dollar quote or comment at the end marks its opener;
    /// - a position inside a dollar-quoted function body marks the token there;
    /// - otherwise the token at the position (the last token for `at end of input`), widened to a qualified name the
    ///   message spells from there (`shop.t`) or to the whole call of an unknown function (`abs(1,2,3)`).
    ///
    /// Without a position: the internal query (`q`/`p`) where it appears in the text, then the named object (also
    /// inside dollar-quoted bodies), then the statement the context quotes, then the `DO` body line the context names.
    /// `nil` when nothing can be located.
    public static func range(in source: String, executed: String? = nil, mapping: SQLExecutedTextMapping = .identity,
                             error: SQLServerError) -> Range<Int>? {
        let lexer = SQLLexer(source)
        let tokens = lexer.tokens()
        guard tokens.contains(where: { $0.kind != .comment }) else { return nil }
        let length = lexer.units.count

        if let position = error.position,
           let executedOffset = utf16Offset(ofCharacter: position, in: executed.map { Array($0.utf16) } ?? lexer.units) {
            return locate(at: min(mapping.sourceOffset(forExecuted: executedOffset), length), lexer: lexer, tokens: tokens, error: error)
        }
        if let query = error.internalQuery, !query.isEmpty, let position = error.internalPosition,
           let found = locateInternalQuery(query, position: position, in: source, error: error) {
            return found
        }
        for name in error.names {
            var segments = name[...]
            while !segments.isEmpty {
                if let found = search(Array(segments), lexer: lexer, tokens: tokens) { return found }
                segments = segments.dropFirst()
            }
        }
        if let context = error.context {
            if let statement = quotedStatement(in: context), let found = occurrence(of: statement, in: source) { return found }
            if let found = doBlockLine(context: context, lexer: lexer, tokens: tokens) { return found }
        }
        return nil
    }

    /// For a simple-protocol script: the range to mark and the statement it belongs to. A position counts from the
    /// start of the script. Without one, only the statement that failed — the one after the `completedStatements`
    /// that completed — is searched, so a name elsewhere in the script is never marked; unknown → `nil`.
    public static func scriptRange(in script: String, error: SQLServerError,
                                   completedStatements: Int?) -> (range: Range<Int>, statement: Range<Int>)? {
        let statements = SQLStatementSplitter.split(script)
        if error.position != nil {
            guard let found = range(in: script, error: error) else { return nil }
            let statement = statements.first { $0.range.lowerBound <= found.lowerBound && found.upperBound <= $0.range.upperBound }
            return (found, statement?.range ?? 0..<script.utf16.count)
        }
        guard let completedStatements, statements.indices.contains(completedStatements) else { return nil }
        let statement = statements[completedStatements]
        guard let found = range(in: statement.text, error: error) else { return nil }
        let base = statement.range.lowerBound
        return ((base + found.lowerBound)..<(base + found.upperBound), statement.range)
    }

    // MARK: Positions

    /// UTF-16 offset of a 1-based code-point position, clamped to the end; nil for non-positive positions.
    static func utf16Offset(ofCharacter position: Int, in units: [UInt16]) -> Int? {
        guard position >= 1 else { return nil }
        var index = 0
        var remaining = position - 1
        while remaining > 0, index < units.count {
            if UTF16.isLeadSurrogate(units[index]), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
                index += 2
            } else {
                index += 1
            }
            remaining -= 1
        }
        return index
    }

    /// The range for a position in `lexer`'s text; `tokens` has at least one non-comment token.
    static func locate(at offset: Int, lexer: SQLLexer, tokens: [SQLToken], error: SQLServerError) -> Range<Int> {
        // PostgreSQL reports an unterminated token where it starts.
        if let last = tokens.last, let unterminated = lexer.unterminated(last), offset >= last.range.lowerBound {
            return unterminated.opener
        }
        let significant = tokens.filter { $0.kind != .comment }
        let index = tokenIndex(at: offset, in: significant)
        let token = significant[index]
        // Inside a function body: `CREATE FUNCTION … AS $$ … $$` errors are reported in the CREATE text.
        if token.range.lowerBound < offset, let body = lexer.dollarQuotedBody(token), body.lowerBound <= offset, offset <= body.upperBound {
            let inner = SQLLexer(lexer.text(in: body))
            let innerTokens = inner.tokens()
            if innerTokens.contains(where: { $0.kind != .comment }) {
                let found = locate(at: offset - body.lowerBound, lexer: inner, tokens: innerTokens, error: error)
                return (body.lowerBound + found.lowerBound)..<(body.lowerBound + found.upperBound)
            }
        }
        return widen(index, in: significant, lexer: lexer, error: error)
    }

    /// The token, widened to a qualified name the message spells from it, and to the call of an unknown function.
    static func widen(_ index: Int, in tokens: [SQLToken], lexer: SQLLexer, error: SQLServerError) -> Range<Int> {
        var last = index
        for name in error.names where name.count > 1 {
            if let end = sequenceEnd(name, startingAt: index, in: tokens, lexer: lexer) {
                last = end
                break
            }
        }
        if error.sqlState == "42883", isName(tokens[index]), last + 1 < tokens.count, isPunctuation(tokens[last + 1], 0x28, lexer),
           let close = matchingParenthesis(from: last + 1, in: tokens, lexer: lexer) {
            last = close
        }
        return tokens[index].range.lowerBound..<tokens[last].range.upperBound
    }

    /// The token containing `offset`, else the last token ending at or before it, else the first.
    static func tokenIndex(at offset: Int, in tokens: [SQLToken]) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let mid = (low + high) / 2
            if tokens[mid].range.upperBound <= offset { low = mid + 1 } else { high = mid }
        }
        if low < tokens.count, tokens[low].range.lowerBound <= offset { return low }
        return max(0, low - 1)
    }

    static func matchingParenthesis(from open: Int, in tokens: [SQLToken], lexer: SQLLexer) -> Int? {
        var depth = 0
        for index in open..<tokens.count where tokens[index].kind == .punctuation {
            switch lexer.units[tokens[index].range.lowerBound] {
            case 0x28:
                depth += 1
            case 0x29:
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }

    // MARK: Internal queries and context

    /// `q`/`p`: the internal query where it appears in `source` (verbatim, or inside a string literal with its quotes
    /// doubled, as in `EXECUTE '…'`), and the token at `p` in it.
    static func locateInternalQuery(_ query: String, position: Int, in source: String, error: SQLServerError) -> Range<Int>? {
        let inner = SQLLexer(query)
        let innerTokens = inner.tokens()
        guard innerTokens.contains(where: { $0.kind != .comment }),
              let offset = utf16Offset(ofCharacter: position, in: inner.units) else { return nil }
        let found = locate(at: min(offset, inner.units.count), lexer: inner, tokens: innerTokens, error: error)
        let haystack = source as NSString
        let verbatim = haystack.range(of: query, options: .literal)
        if verbatim.location != NSNotFound {
            return (verbatim.location + found.lowerBound)..<(verbatim.location + found.upperBound)
        }
        guard query.contains("'") else { return nil }
        let escaped = haystack.range(of: query.replacingOccurrences(of: "'", with: "''"), options: .literal)
        guard escaped.location != NSNotFound else { return nil }
        // Every quote before an offset was doubled.
        func shifted(_ offset: Int) -> Int {
            offset + inner.units[..<min(offset, inner.units.count)].lazy.filter { $0 == 0x27 }.count
        }
        return (escaped.location + shifted(found.lowerBound))..<(escaped.location + shifted(found.upperBound))
    }

    /// The statement a context quotes: `SQL statement "SELECT 1/0"`, `PL/pgSQL assignment "x := 1/0"`.
    static func quotedStatement(in context: String) -> String? {
        for prefix in ["SQL statement \"", "PL/pgSQL assignment \"", "PL/pgSQL expression \""] where context.hasPrefix(prefix) {
            let rest = context.dropFirst(prefix.count)
            let end = rest.range(of: "\"\n")?.lowerBound ?? (rest.hasSuffix("\"") ? rest.index(before: rest.endIndex) : nil)
            guard let end else { return nil }
            let statement = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            return statement.isEmpty ? nil : statement
        }
        return nil
    }

    static func occurrence(of needle: String, in text: String) -> Range<Int>? {
        let found = (text as NSString).range(of: needle, options: .literal)
        guard found.location != NSNotFound, found.length > 0 else { return nil }
        return found.location..<NSMaxRange(found)
    }

    /// `PL/pgSQL function inline_code_block line N`: line N of the `DO` block's body (line 1 starts right after the
    /// opening quote), without its indentation.
    static func doBlockLine(context: String, lexer: SQLLexer, tokens: [SQLToken]) -> Range<Int>? {
        guard let match = context.firstMatch(of: /inline_code_block line (\d{1,9})/), let line = Int(match.output.1), line >= 1 else { return nil }
        let significant = tokens.filter { $0.kind != .comment }
        guard let first = significant.first, lexer.word(of: first) == "DO",
              let bodyToken = significant.dropFirst().first(where: { $0.kind == .string }) else { return nil }
        let body: Range<Int>
        if let dollar = lexer.dollarQuotedBody(bodyToken) {
            body = dollar
        } else if lexer.units[bodyToken.range.lowerBound] == 0x27, bodyToken.range.count >= 2 {
            body = (bodyToken.range.lowerBound + 1)..<(bodyToken.range.upperBound - 1)
        } else {
            return nil
        }
        let units = lexer.units
        var start = body.lowerBound
        var current = 1
        while current < line {
            guard let newline = units[start..<body.upperBound].firstIndex(of: 0x0A) else { return nil }
            start = newline + 1
            current += 1
        }
        var end = units[start..<body.upperBound].firstIndex(of: 0x0A) ?? body.upperBound
        func isBlank(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 || unit == 0x0D }
        while start < end, isBlank(units[start]) { start += 1 }
        while end > start, isBlank(units[end - 1]) { end -= 1 }
        return start < end ? start..<end : nil
    }

    // MARK: Names

    /// The first place `segments` are spelled as `a . b . c`: among the statement's tokens, then inside its
    /// dollar-quoted bodies (function and `DO` bodies).
    static func search(_ segments: [String], lexer: SQLLexer, tokens: [SQLToken]) -> Range<Int>? {
        let significant = tokens.filter { $0.kind != .comment }
        for start in significant.indices {
            if let end = sequenceEnd(segments, startingAt: start, in: significant, lexer: lexer) {
                return significant[start].range.lowerBound..<significant[end].range.upperBound
            }
        }
        for token in significant {
            guard let body = lexer.dollarQuotedBody(token), !body.isEmpty else { continue }
            let inner = SQLLexer(lexer.text(in: body))
            if let found = search(segments, lexer: inner, tokens: inner.tokens()) {
                return (body.lowerBound + found.lowerBound)..<(body.lowerBound + found.upperBound)
            }
        }
        return nil
    }

    /// Index of the last token when `segments` are spelled from `start`. Identifiers are compared as PostgreSQL
    /// resolves them: unquoted ones folded to lower case, quoted ones exactly.
    static func sequenceEnd(_ segments: [String], startingAt start: Int, in tokens: [SQLToken], lexer: SQLLexer) -> Int? {
        guard !segments.isEmpty, start >= 0 else { return nil }
        let end = start + segments.count * 2 - 2
        guard end < tokens.count else { return nil }
        for (offset, name) in segments.enumerated() {
            let token = tokens[start + offset * 2]
            guard isName(token), lexer.identifierValue(of: token) == name else { return nil }
            if offset > 0, !isPunctuation(tokens[start + offset * 2 - 1], 0x2E, lexer) { return nil }
        }
        return end
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    static func isPunctuation(_ token: SQLToken, _ unit: UInt16, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == unit
    }
}
