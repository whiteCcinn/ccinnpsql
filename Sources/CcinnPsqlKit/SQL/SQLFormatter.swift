import Foundation

/// How `SQLFormatter` lays out SQL.
public struct SQLFormatOptions: Sendable, Equatable {
    public enum KeywordCase: String, Sendable, CaseIterable, Identifiable {
        case upper, lower, preserve
        public var id: String { rawValue }
    }

    public var keywordCase: KeywordCase
    /// Spaces per indent level (1…8; set through `init`, which clamps it).
    public private(set) var indentWidth: Int

    public init(keywordCase: KeywordCase = .upper, indentWidth: Int = 2) {
        self.keywordCase = keywordCase
        self.indentWidth = Self.clampedIndentWidth(indentWidth)
    }

    static func clampedIndentWidth(_ width: Int) -> Int { min(max(width, 1), 8) }
}

/// Why `SQLFormatter` left the text as it was.
public enum SQLFormatError: Error, Sendable, Equatable {
    /// The result would differ from the input in more than whitespace and the letter case of keywords.
    case notEquivalent
    /// Nested deeper than `SQLFormatter.maximumNesting`, or the layout would make the text more than
    /// `SQLFormatter.maximumGrowth` times longer.
    case tooComplex
    /// The task formatting the text was cancelled.
    case cancelled
    /// The selection is not inside the text.
    case invalidSelection
    /// The text has whitespace that PostgreSQL versions read differently: a vertical tab between tokens is whitespace to 16+
    /// and an error to 13, so removing it would turn an error into a statement that runs.
    case versionDependent
    /// The text contains a NUL character, which PostgreSQL cannot receive (the app refuses to send it).
    case nulCharacter
}

/// The formatted text of a selection and the range it replaces: the selection widened to whole tokens.
public struct SQLFormatReplacement: Sendable, Equatable {
    /// UTF-16 range in the original text.
    public let range: NSRange
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// Formats PostgreSQL SQL by deciding the whitespace between the lexer's tokens.
///
/// Only whitespace and the letter case of keywords change:
/// - words PostgreSQL reserves in every supported version (`reservedKeywords`), except where they are names (next to `.`,
///   or a label after AS);
/// - other keywords only where their position proves them keywords (a statement's command words, `ORDER BY`, join
///   operators, window frames, `NULLS FIRST` after sort items, locking clauses, triggers, …).
///
/// Names, functions, type names, strings (dollar-quoted function bodies included), quoted identifiers and comments keep
/// their exact text. Tokens written together stay together unless punctuation or an operator is involved (`123abc`,
/// `date'2024-01-01'`), and two string literals keep the newline between them when they had one (PostgreSQL
/// concatenates only those). Lines end as the input's do (`\n`, `\r\n` or `\r`). The result is re-lexed with the number
/// syntax of every server version and compared with the input; if anything else differs, formatting fails rather than
/// produce a text that might mean something else.
public enum SQLFormatter {
    /// `pg_get_keywords()` with catcode `R` on PostgreSQL 13, 17 and 18 (`SYSTEM_USER` is reserved only from 16, so it
    /// is not here). The integration tests check this set against every tested server.
    public static let reservedKeywords: Set<String> = [
        "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "ASYMMETRIC", "BOTH", "CASE", "CAST",
        "CHECK", "COLLATE", "COLUMN", "CONSTRAINT", "CREATE", "CURRENT_CATALOG", "CURRENT_DATE", "CURRENT_ROLE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "CURRENT_USER", "DEFAULT", "DEFERRABLE", "DESC", "DISTINCT", "DO", "ELSE", "END", "EXCEPT", "FALSE",
        "FETCH", "FOR", "FOREIGN", "FROM", "GRANT", "GROUP", "HAVING", "IN", "INITIALLY", "INTERSECT", "INTO", "LATERAL",
        "LEADING", "LIMIT", "LOCALTIME", "LOCALTIMESTAMP", "NOT", "NULL", "OFFSET", "ON", "ONLY", "OR", "ORDER", "PLACING",
        "PRIMARY", "REFERENCES", "RETURNING", "SELECT", "SESSION_USER", "SOME", "SYMMETRIC", "TABLE", "THEN", "TO", "TRAILING",
        "TRUE", "UNION", "UNIQUE", "USER", "USING", "VARIADIC", "WHEN", "WHERE", "WINDOW", "WITH",
    ]
    /// Deeper levels are written at this indent level.
    public static let maximumIndentLevel = 16
    /// Parentheses and brackets nested deeper than this are not formatted.
    public static let maximumNesting = 1_000
    /// The formatted text may be at most this many times as long as the input (plus `growthAllowance`).
    public static let maximumGrowth = 8
    static let growthAllowance = 16_384
    /// The engine lays out the tokens of the newest server syntax: they are never finer than an older version's, and
    /// `123abc` (trailing junk from PostgreSQL 15 on) is one token there.
    static let layoutSyntax = SQLLexer.Syntax.postgres16

    /// The formatted text, or `nil` when it cannot be formatted safely (see `formatted(_:options:)`).
    public static func format(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) -> String? {
        try? formatted(text, options: options)
    }

    /// Formats a whole text. Call it off the main actor: it stops with `.cancelled` when its task is cancelled.
    public static func formatted(_ text: String, options: SQLFormatOptions = SQLFormatOptions()) throws(SQLFormatError) -> String {
        let lexer = SQLLexer(text, syntax: layoutSyntax)
        guard !lexer.units.contains(0) else { throw .nulCharacter }
        let tokens = lexer.tokens()
        guard let last = tokens.last else { return "" }
        guard !hasVerticalTab(lexer, tokens: tokens, from: 0, to: lexer.units.count) else { throw .versionDependent }
        let lineBreak = lineBreak(of: lexer, tokens: tokens)
        var engine = Engine(lexer: lexer, tokens: tokens, options: options, continuesStatement: false, lineBreak: lineBreak)
        var output = try engine.run()
        // Keep a trailing newline only when the input ended with one after its last token.
        if lexer.units[last.range.upperBound...].contains(where: isLineBreak) { output += lineBreak }
        guard !Task.isCancelled else { throw .cancelled }
        guard equivalent(text, output, caseChangeable: Set(engine.caseChangeable.map { tokens[$0].range })) else { throw .notEquivalent }
        return output
    }

    /// Formats the part of `text` in `range` (UTF-16). The selection is widened to the whole tokens it touches (half a
    /// string or a name is never reformatted on its own) and narrowed to them (surrounding whitespace stays as it is).
    /// The whole text with the replacement is checked against the original.
    public static func formatSelection(in text: String, range: NSRange,
                                       options: SQLFormatOptions = SQLFormatOptions()) throws(SQLFormatError) -> SQLFormatReplacement {
        let lexer = SQLLexer(text, syntax: layoutSyntax)
        guard !lexer.units.contains(0) else { throw .nulCharacter }
        let length = lexer.units.count
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else {
            throw .invalidSelection
        }
        let unchanged = SQLFormatReplacement(range: range, text: lexer.text(in: range.location..<NSMaxRange(range)))
        let tokens = lexer.tokens()
        let lower = range.location
        let upper = NSMaxRange(range)
        // Tokens the selection touches: ending after its start and starting before its end.
        let first = tokens.partitioningIndex { $0.range.upperBound > lower }
        let end = tokens.partitioningIndex { $0.range.lowerBound >= upper }
        guard range.length > 0, first < end else { return unchanged }
        let start = tokens[first].range.lowerBound
        let stop = tokens[end - 1].range.upperBound
        guard !hasVerticalTab(lexer, tokens: Array(tokens[first..<end]), from: start, to: stop) else { throw .versionDependent }
        let before = tokens[..<first].last { $0.kind != .comment }
        let after = tokens[end...].first { $0.kind != .comment }
        let isDot = { (token: SQLToken?) in token.map { $0.kind == .punctuation && lexer.text(of: $0) == "." } == true }
        // A fragment after anything but `;` continues a statement: its first words are not command words.
        let continues = before.map { !($0.kind == .punctuation && lexer.text(of: $0) == ";") } ?? false
        var engine = Engine(lexer: lexer, tokens: Array(tokens[first..<end]), options: options, continuesStatement: continues,
                            lineBreak: lineBreak(of: lexer, tokens: tokens), dotBefore: isDot(before), dotAfter: isDot(after))
        let output = try engine.run()
        let snapped = NSRange(location: start, length: stop - start)
        let spliced = lexer.text(in: 0..<start) + output + lexer.text(in: stop..<length)
        guard !Task.isCancelled else { throw .cancelled }
        let changeable = Set(engine.caseChangeable.map { tokens[first + $0].range })
        guard equivalent(text, spliced, caseChangeable: changeable) else { throw .notEquivalent }
        return SQLFormatReplacement(range: snapped, text: output)
    }

    /// The offset in `formatted` that corresponds to `offset` in `original`: the position after the same number of
    /// non-whitespace UTF-16 units. Exact for formatter output, which only changes whitespace and letter case.
    public static func mapOffset(_ offset: Int, from original: String, to formatted: String) -> Int {
        let source = Array(original.utf16)
        let target = Array(formatted.utf16)
        let end = min(max(0, offset), source.count)
        let count = source[..<end].reduce(0) { $0 + (isWhitespace($1) ? 0 : 1) }
        var index = 0
        var seen = 0
        while index < target.count, seen < count {
            if !isWhitespace(target[index]) { seen += 1 }
            index += 1
        }
        return index
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D || unit == 0x0B || unit == 0x0C
    }

    static func isLineBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }

    /// A vertical tab (U+000B) in the whitespace between `tokens`, from `lower` to `upper`: the whitespace the formatter
    /// rewrites. (Inside a string or comment it is text and stays.)
    static func hasVerticalTab(_ lexer: SQLLexer, tokens: [SQLToken], from lower: Int, to upper: Int) -> Bool {
        var gapStart = lower
        for token in tokens + [SQLToken(kind: .comment, range: upper..<upper)] {
            if lexer.units[gapStart..<max(gapStart, min(token.range.lowerBound, upper))].contains(0x0B) { return true }
            gapStart = max(gapStart, token.range.upperBound)
        }
        return false
    }

    /// The readings the check compares a text under: each server version's number syntax, and when the text has a backslash,
    /// each also with standard_conforming_strings off (`'don\'t   panic'` is then one string).
    static func readings(of text: String) -> [SQLLexer.Syntax] {
        let servers = SQLLexer.Syntax.servers
        guard text.utf16.contains(0x5C) else { return servers }
        return servers + servers.map { $0.with(standardConformingStrings: false) }
    }

    /// The input's line break (`\r\n`, `\r` or `\n`): the first one between tokens (one inside a string or comment is the
    /// token's own), else the first one anywhere, else `\n`.
    static func lineBreak(of lexer: SQLLexer, tokens: [SQLToken]) -> String {
        let units = lexer.units
        var gapStart = 0
        var found: Int?
        for token in tokens + [SQLToken(kind: .comment, range: units.count..<units.count)] {
            if let index = units[gapStart..<max(gapStart, token.range.lowerBound)].firstIndex(where: isLineBreak) {
                found = index
                break
            }
            gapStart = max(gapStart, token.range.upperBound)
        }
        guard let index = found ?? units.firstIndex(where: isLineBreak), units[index] == 0x0D else { return "\n" }
        return index + 1 < units.count && units[index + 1] == 0x0A ? "\r\n" : "\r"
    }

    /// Whitespace may go between this token and one written right next to it: comments, punctuation other than `.` / `..`,
    /// and operators other than `::` / `:` (`a+b`, `f(x)`, `x,y`). Never elsewhere (`123abc`, `$1::int`, `t.a`, `a[1:2]`,
    /// `date'…'`, `U&'…'UESCAPE'…'`).
    static func maySpace(_ token: SQLToken, in lexer: SQLLexer) -> Bool {
        switch token.kind {
        case .comment: return true
        case .punctuation:
            return !(token.range.count <= 2 && lexer.units[token.range].allSatisfy { $0 == 0x2E })
        case .operator:
            return !(token.range.count <= 2 && lexer.units[token.range].allSatisfy { $0 == 0x3A })
        default: return false
        }
    }

    /// Same tokens in the same order with the same texts on every server version, except the ASCII letter case of
    /// keywords. A lower bound of what `format` checks (it allows case changes only on the keywords it changed).
    public static func sameTokens(_ lhs: String, _ rhs: String) -> Bool {
        readings(of: lhs).allSatisfy { syntax in
            let lexer = SQLLexer(lhs, syntax: syntax)
            let keywords = lexer.tokens().filter { $0.kind == .keyword }.map(\.range)
            return equivalent(lhs, rhs, caseChangeable: Set(keywords), syntaxes: [syntax], checksAdjacency: false)
        }
    }

    /// For every two string literals with only whitespace and comments between them, a newline between them in both
    /// texts or in neither: PostgreSQL concatenates `'a'` newline `'b'` into `'ab'` and rejects `'a' 'b'`.
    public static func sameStringContinuations(_ lhs: String, _ rhs: String) -> Bool {
        continuations(SQLLexer(lhs)) == continuations(SQLLexer(rhs))
    }

    private static func continuations(_ lexer: SQLLexer) -> [Bool] {
        let significant = lexer.tokens().filter { $0.kind != .comment }
        var result: [Bool] = []
        for index in significant.indices.dropFirst() where significant[index - 1].kind == .string && significant[index].kind == .string {
            let gap = lexer.units[significant[index - 1].range.upperBound..<significant[index].range.lowerBound]
            result.append(gap.contains(where: isLineBreak))
        }
        return result
    }

    /// `output` means what `input` means under every reading (`readings(of:)`: each server version's number syntax, and
    /// standard_conforming_strings on and off):
    /// - the same tokens (kinds and texts), except that words whose input range is in `caseChangeable` may differ in the
    ///   case of ASCII letters, the only case PostgreSQL folds;
    /// - tokens written together in the input are still together unless one of them may be spaced (`maySpace`);
    /// - two string literals in a row have a line break between them in both texts or in neither.
    static func equivalent(_ input: String, _ output: String, caseChangeable: Set<Range<Int>>,
                           syntaxes: [SQLLexer.Syntax]? = nil, checksAdjacency: Bool = true) -> Bool {
        (syntaxes ?? readings(of: input)).allSatisfy { syntax in
            let before = SQLLexer(input, syntax: syntax)
            let after = SQLLexer(output, syntax: syntax)
            let old = before.tokens()
            let new = after.tokens()
            guard old.count == new.count else { return false }
            var previousSignificant: Int?
            for index in old.indices {
                let token = old[index]
                let other = new[index]
                guard token.kind == other.kind, token.range.count == other.range.count else { return false }
                let original = before.units[token.range]
                let formatted = after.units[other.range]
                if !original.elementsEqual(formatted) {
                    guard caseChangeable.contains(token.range), token.kind == .keyword || token.kind == .identifier,
                          original.elementsEqual(formatted, by: { asciiLowercased($0) == asciiLowercased($1) }) else { return false }
                }
                if checksAdjacency, index > 0, old[index - 1].range.upperBound == token.range.lowerBound,
                   !maySpace(old[index - 1], in: before), !maySpace(token, in: before),
                   new[index - 1].range.upperBound != other.range.lowerBound {
                    return false
                }
                guard token.kind != .comment else { continue }
                if let previous = previousSignificant, old[previous].kind == .string, token.kind == .string {
                    let wasContinued = before.units[old[previous].range.upperBound..<token.range.lowerBound].contains(where: isLineBreak)
                    let isContinued = after.units[new[previous].range.upperBound..<other.range.lowerBound].contains(where: isLineBreak)
                    guard wasContinued == isContinued else { return false }
                }
                previousSignificant = index
            }
            return true
        }
    }

    static func asciiLowercased(_ unit: UInt16) -> UInt16 { unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit }
    static func asciiUppercased(_ unit: UInt16) -> UInt16 { unit >= 0x61 && unit <= 0x7A ? unit - 0x20 : unit }
}

extension Array {
    /// Index of the first element for which `belongs` is true, for an array where it is false and then true.
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if belongs(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
