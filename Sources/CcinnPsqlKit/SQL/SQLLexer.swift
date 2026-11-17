import Foundation

/// One lexical token. Ranges are UTF-16 offsets so they map 1:1 onto `NSRange` in the editor.
public struct SQLToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyword
        case identifier
        /// `"name"` or `U&"name"`.
        case quotedIdentifier
        /// `'…'`, `E'…'`, `U&'…'`, `B'…'`, `X'…'`, `N'…'` and dollar-quoted `$tag$…$tag$`.
        case string
        case number
        case comment
        case `operator`
        /// `( ) , ; . [ ]`
        case punctuation
        /// `$1` positional parameter.
        case parameter
    }

    public let kind: Kind
    public let range: Range<Int>

    public init(kind: Kind, range: Range<Int>) {
        self.kind = kind
        self.range = range
    }

    public var nsRange: NSRange { NSRange(location: range.lowerBound, length: range.count) }
}

/// A token that runs to the end of the input without its closing delimiter.
public struct SQLUnterminatedToken: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case string
        case quotedIdentifier
        case dollarQuote(tag: String)
        /// Block comments nest in PostgreSQL; `openDepth` closing `*/` are missing.
        case blockComment(openDepth: Int)
    }

    public let kind: Kind
    /// The opening delimiter with its prefix: `'`, `E'`, `U&'`, `"`, `U&"`, `$tag$` or `/*`.
    public let opener: Range<Int>
}

/// Tokenizer for PostgreSQL SQL (design D12). Never fails: unterminated strings and comments extend to the end
/// of the input, unknown characters become operators. Linear time over UTF-16 code units; nested block comments
/// and dollar quotes are understood, so keywords inside strings, comments and function bodies are never seen.
public struct SQLLexer: Sendable {
    /// How a reader tokenizes: where numbers and positional parameters end (PostgreSQL changed it in 15 and 16, scan.l),
    /// and which words are keywords.
    public struct Syntax: Sendable, Hashable {
        /// `0x1F`, `0o17`, `0b101`, and `_` between digits (`1_000`).
        public let extendedLiterals: Bool
        /// A word written right after a number or parameter makes one invalid token with it (`123abc`: "trailing junk").
        public let joinsTrailingWords: Bool
        /// Keywords are matched after folding ASCII letters only, as PostgreSQL does (`ınto` is a name). Otherwise every
        /// Unicode case mapping counts (`ınto` upper-cases to INTO): a superset, so a reader that must not miss a keyword
        /// sees it whichever folding applies.
        public let asciiKeywordsOnly: Bool
        /// The server setting `standard_conforming_strings` (on by default since 9.1): when off, a backslash escapes the next
        /// character in `'…'` and `N'…'` too, so `'don\'t'` is one string.
        public private(set) var standardConformingStrings = true

        init(extendedLiterals: Bool, joinsTrailingWords: Bool, asciiKeywordsOnly: Bool) {
            self.extendedLiterals = extendedLiterals
            self.joinsTrailingWords = joinsTrailingWords
            self.asciiKeywordsOnly = asciiKeywordsOnly
        }

        /// This syntax with `standard_conforming_strings` on or off.
        public func with(standardConformingStrings: Bool) -> Syntax {
            var syntax = self
            syntax.standardConformingStrings = standardConformingStrings
            return syntax
        }

        /// PostgreSQL 14 and earlier: `123abc` is `123` then `abc`, `0x1F` is `0` then `x1F`.
        public static let postgres14 = Syntax(extendedLiterals: false, joinsTrailingWords: false, asciiKeywordsOnly: true)
        /// PostgreSQL 16 and later. (15 already rejects trailing junk, without the new literals: two tokens it joins are
        /// joined by 16 as well.)
        public static let postgres16 = Syntax(extendedLiterals: true, joinsTrailingWords: true, asciiKeywordsOnly: true)
        /// The editor's, and the read-only guard's: 16's literals, a word after a number is its own token as before 15, and
        /// keywords under any case mapping. Every keyword a server version sees in text it accepts is a keyword here too
        /// (16+ reads `1E--x` as the invalid `1E-` and code, 13 and this syntax as `1`, `E` and a comment). The guard also
        /// reads each server syntax, so it never relies on this one alone.
        public static let editor = Syntax(extendedLiterals: true, joinsTrailingWords: false, asciiKeywordsOnly: false)
        /// The syntaxes of the server versions, for checks that must hold on every one.
        public static let servers: [Syntax] = [.postgres14, .postgres16]
    }

    public let units: [UInt16]
    public let syntax: Syntax

    public init(_ text: String, syntax: Syntax = .editor) {
        units = Array(text.utf16)
        self.syntax = syntax
    }

    public static func tokenize(_ text: String) -> [SQLToken] {
        SQLLexer(text).tokens()
    }

    /// Source text of a token (quotes kept).
    public func text(of token: SQLToken) -> String {
        text(in: token.range)
    }

    public func text(in range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        return String(decoding: units[lower..<upper], as: UTF16.self)
    }

    /// Identifier value: unquoted identifiers fold to lower case (as PostgreSQL does), quoted ones keep their case
    /// with doubled quotes unescaped.
    public func identifierValue(of token: SQLToken) -> String {
        let raw = text(of: token)
        guard token.kind == .quotedIdentifier else { return raw.lowercased() }
        var inner = Substring(raw)
        if inner.hasPrefix("U&") || inner.hasPrefix("u&") { inner = inner.dropFirst(2) }
        inner = inner.dropFirst()
        if inner.hasSuffix("\"") { inner = inner.dropLast() }
        return inner.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// Upper-cased word for keywords/identifiers (ASCII letters only when the syntax folds only those), raw text otherwise.
    public func word(of token: SQLToken) -> String {
        guard token.kind == .keyword || token.kind == .identifier else { return text(of: token) }
        return syntax.asciiKeywordsOnly ? asciiUppercased(token.range) : text(of: token).uppercased()
    }

    /// The text in `range` with ASCII letters upper-cased and every other character as it is.
    public func asciiUppercased(_ range: Range<Int>) -> String {
        let lower = max(0, min(range.lowerBound, units.count))
        let upper = max(lower, min(range.upperBound, units.count))
        return String(decoding: units[lower..<upper].lazy.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, as: UTF16.self)
    }

    public func tokens() -> [SQLToken] {
        var tokens: [SQLToken] = []
        tokens.reserveCapacity(units.count / 4)
        var index = 0
        let count = units.count
        while index < count {
            let unit = units[index]
            let start = index
            switch unit {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C:
                index += 1
                continue
            case 0x2D where peek(index + 1) == 0x2D: // --
                index = endOfLine(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x2F where peek(index + 1) == 0x2A: // /* nested */
                index = endOfBlockComment(from: index)
                tokens.append(SQLToken(kind: .comment, range: start..<index))
            case 0x27: // '
                index = endOfQuoted(from: index, quote: 0x27, backslashEscapes: !syntax.standardConformingStrings)
                tokens.append(SQLToken(kind: .string, range: start..<index))
            case 0x22: // "
                index = endOfQuoted(from: index, quote: 0x22, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x24: // $
                if let digitsEnd = parameterEnd(from: index) {
                    index = syntax.joinsTrailingWords ? endOfWord(from: digitsEnd) : digitsEnd
                    tokens.append(SQLToken(kind: .parameter, range: start..<index))
                } else if let tagEnd = dollarTagEnd(from: index) {
                    index = endOfDollarQuote(from: index, tagEnd: tagEnd)
                    tokens.append(SQLToken(kind: .string, range: start..<index))
                } else {
                    index += 1
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            case 0x30...0x39:
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x2E where peek(index + 1).map(Self.isDigit) == true: // `.5`, also after a name (`t.5` is `t` then `.5`)
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x2E where peek(index + 1) == 0x2E: // `..` is one token to the server
                index += 2
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            case 0x28, 0x29, 0x2C, 0x3B, 0x2E, 0x5B, 0x5D: // ( ) , ; . [ ]
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if let prefixed = prefixedLiteral(at: index) {
                    index = prefixed.end
                    tokens.append(SQLToken(kind: prefixed.kind, range: start..<index))
                } else if Self.isIdentifierStart(unit) {
                    while index < count, Self.isIdentifierPart(units[index]) { index += 1 }
                    tokens.append(SQLToken(kind: isKeyword(start..<index) ? .keyword : .identifier, range: start..<index))
                } else {
                    index += 1
                    // PostgreSQL operators are runs of + - * / < > = ~ ! @ # % ^ & | ` ? (and `::`, `:=`).
                    if Self.isOperatorCharacter(unit) {
                        // The whole run, however long: the server reads it as one ("operator too long" past 63).
                        while index < count, Self.isOperatorCharacter(units[index]),
                              !(units[index] == 0x2D && peek(index + 1) == 0x2D),
                              !(units[index] == 0x2F && peek(index + 1) == 0x2A) {
                            index += 1
                        }
                        // As the server: trailing `+`/`-` are separate operators unless one of ~ ! @ # % ^ & | ` ?
                        // appears (`=-1` is `=` then `-`).
                        if index - start > 1, !units[start..<index].contains(where: Self.allowsTrailingSign) {
                            while index - start > 1, units[index - 1] == 0x2B || units[index - 1] == 0x2D { index -= 1 }
                        }
                    } else if unit == 0x3A, let next = peek(index), next == 0x3A || next == 0x3D { // :: :=
                        index += 1
                    }
                    tokens.append(SQLToken(kind: .operator, range: start..<index))
                }
            }
        }
        return tokens
    }

    // MARK: Scanners

    private func peek(_ index: Int) -> UInt16? { index >= 0 && index < units.count ? units[index] : nil }

    /// A keyword: a word in the vocabulary. PostgreSQL folds only ASCII letters, so with `asciiKeywordsOnly` a word with any
    /// other character (`ﬁrst`, which Unicode upper-cases to FIRST) is a name; otherwise it is a keyword too (see `Syntax`).
    private func isKeyword(_ range: Range<Int>) -> Bool {
        guard units[range].contains(where: { $0 >= 0x80 }) else {
            return range.count <= SQLKeywords.longestWord && SQLKeywords.all.contains(asciiUppercased(range))
        }
        return !syntax.asciiKeywordsOnly && SQLKeywords.all.contains(text(in: range).uppercased())
    }

    /// End of the word starting at `index` (letters, digits, `_`, `$`, any non-ASCII character), or `index` when none starts
    /// there.
    private func endOfWord(from index: Int) -> Int {
        guard index < units.count, Self.isIdentifierStart(units[index]) else { return index }
        var end = index + 1
        while end < units.count, Self.isIdentifierPart(units[end]) { end += 1 }
        return end
    }

    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
        return index
    }

    private func endOfBlockComment(from index: Int) -> Int {
        scanBlockComment(from: index).end
    }

    /// End of a nested block comment and the depth still open there (0 when it is closed).
    private func scanBlockComment(from index: Int) -> (end: Int, openDepth: Int) {
        var depth = 0
        var index = index
        while index < units.count {
            if units[index] == 0x2F, peek(index + 1) == 0x2A {
                depth += 1
                index += 2
            } else if units[index] == 0x2A, peek(index + 1) == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return (index, 0) }
            } else {
                index += 1
            }
        }
        return (units.count, max(0, depth))
    }

    private func endOfQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool, doubledQuotes: Bool = true) -> Int {
        scanQuoted(from: index, quote: quote, backslashEscapes: backslashEscapes, doubledQuotes: doubledQuotes).end
    }

    /// `doubledQuotes`: `''` is a quote inside the literal (not in bit strings, which end at their first quote).
    private func scanQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool, doubledQuotes: Bool = true) -> (end: Int, closed: Bool) {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if backslashEscapes, unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if doubledQuotes, peek(index + 1) == quote {
                    index += 2
                    continue
                }
                return (index + 1, true)
            }
            index += 1
        }
        return (units.count, false)
    }

    /// `$1`, `$23`: positional parameter end, nil otherwise.
    private func parameterEnd(from index: Int) -> Int? {
        var end = index + 1
        guard end < units.count, Self.isDigit(units[end]) else { return nil }
        while end < units.count, Self.isDigit(units[end]) { end += 1 }
        return end
    }

    /// End (exclusive) of an opening dollar-quote tag `$tag$` / `$$`, nil when this `$` does not open one.
    private func dollarTagEnd(from index: Int) -> Int? {
        var end = index + 1
        if end < units.count, units[end] == 0x24 { return end + 1 }
        guard end < units.count, Self.isIdentifierStart(units[end]), units[end] != 0x24 else { return nil }
        while end < units.count, Self.isIdentifierPart(units[end]), units[end] != 0x24 { end += 1 }
        guard end < units.count, units[end] == 0x24 else { return nil }
        return end + 1
    }

    private func endOfDollarQuote(from start: Int, tagEnd: Int) -> Int {
        scanDollarQuote(from: start, tagEnd: tagEnd).end
    }

    private func scanDollarQuote(from start: Int, tagEnd: Int) -> (end: Int, closed: Bool) {
        let tag = units[start..<tagEnd]
        var index = tagEnd
        while index + tag.count <= units.count {
            if units[index] == 0x24, units[index..<(index + tag.count)].elementsEqual(tag) { return (index + tag.count, true) }
            index += 1
        }
        return (units.count, false)
    }

    // MARK: Unterminated tokens

    /// A string, quoted identifier, dollar quote or block comment that runs to the end of the input without its
    /// closing delimiter (PostgreSQL rejects it there). Only the last token can be one, so this rescans at most once.
    public func unterminated(_ token: SQLToken) -> SQLUnterminatedToken? {
        let start = token.range.lowerBound
        guard token.range.upperBound >= units.count, start >= 0, start < units.count else { return nil }
        let first = units[start]
        switch token.kind {
        case .comment:
            guard first == 0x2F, peek(start + 1) == 0x2A else { return nil } // `--` comments end at the line end
            let depth = scanBlockComment(from: start).openDepth
            return depth > 0 ? SQLUnterminatedToken(kind: .blockComment(openDepth: depth), opener: start..<(start + 2)) : nil
        case .string where first == 0x24:
            guard let tagEnd = dollarTagEnd(from: start), !scanDollarQuote(from: start, tagEnd: tagEnd).closed else { return nil }
            return SQLUnterminatedToken(kind: .dollarQuote(tag: text(in: start..<tagEnd)), opener: start..<tagEnd)
        case .string, .quotedIdentifier:
            // The quote follows an optional prefix: `E'` (backslash escapes), `B'`, `X'`, `N'`, `U&'`, `U&"`.
            var quoteIndex = start
            if first != 0x27, first != 0x22 { quoteIndex = peek(start + 1) == 0x26 ? start + 2 : start + 1 }
            guard let quote = peek(quoteIndex), quote == 0x27 || quote == 0x22 else { return nil }
            let (escapes, doubled) = token.kind == .string ? quoteRules(prefix: first) : (false, true)
            guard !scanQuoted(from: quoteIndex, quote: quote, backslashEscapes: escapes, doubledQuotes: doubled).closed else { return nil }
            return SQLUnterminatedToken(kind: token.kind == .string ? .string : .quotedIdentifier, opener: start..<(quoteIndex + 1))
        default:
            return nil
        }
    }

    /// Range of the text between a dollar-quoted string's tags (to the end of the input when it is unterminated);
    /// `nil` for any other token.
    public func dollarQuotedBody(_ token: SQLToken) -> Range<Int>? {
        let start = token.range.lowerBound
        guard token.kind == .string, start >= 0, start < units.count, units[start] == 0x24,
              let tagEnd = dollarTagEnd(from: start), tagEnd <= token.range.upperBound else { return nil }
        let tagLength = tagEnd - start
        let closed = token.range.count >= 2 * tagLength && units[(token.range.upperBound - tagLength)..<token.range.upperBound].elementsEqual(units[start..<tagEnd])
        return tagEnd..<(closed ? token.range.upperBound - tagLength : token.range.upperBound)
    }

    /// How a string literal starting with `prefix` (its first character) ends: backslash escapes in `E'…'` always and in
    /// `'…'` / `N'…'` when standard_conforming_strings is off; `''` is a quote except in bit strings `B'…'` / `X'…'`.
    private func quoteRules(prefix: UInt16) -> (backslashEscapes: Bool, doubledQuotes: Bool) {
        switch prefix {
        case 0x45, 0x65: (true, true)
        case 0x42, 0x62, 0x58, 0x78: (false, false)
        case 0x27, 0x4E, 0x6E: (!syntax.standardConformingStrings, true)
        default: (false, true) // U&'…'
        }
    }

    /// `E'…'`, `U&'…'`, `U&"…"`, `B'…'`, `X'…'`, `N'…'` literals.
    private func prefixedLiteral(at index: Int) -> (end: Int, kind: SQLToken.Kind)? {
        let unit = units[index]
        // The prefix must not continue an identifier (`some'x'` is not a literal).
        switch unit {
        case 0x45, 0x65: // E e
            guard peek(index + 1) == 0x27 else { return nil }
            return (endOfQuoted(from: index + 1, quote: 0x27, backslashEscapes: true), .string)
        case 0x42, 0x62, 0x58, 0x78, 0x4E, 0x6E: // B b X x N n
            guard peek(index + 1) == 0x27 else { return nil }
            let (escapes, doubled) = quoteRules(prefix: unit)
            return (endOfQuoted(from: index + 1, quote: 0x27, backslashEscapes: escapes, doubledQuotes: doubled), .string)
        case 0x55, 0x75: // U&
            guard peek(index + 1) == 0x26, let quote = peek(index + 2), quote == 0x27 || quote == 0x22 else { return nil }
            return (endOfQuoted(from: index + 2, quote: quote, backslashEscapes: false), quote == 0x27 ? .string : .quotedIdentifier)
        default:
            return nil
        }
    }

    /// End of the number starting at `start` (a digit, or `.` before a digit), as the server's scan.l rules for this syntax
    /// end it: the longest match among the literals (and, from 16, their failed forms and trailing junk), where
    /// `1..2` is `1` then `..`, and a failed exponent (`1e+`, before 15) gives back its `e` and sign.
    private func endOfNumber(from start: Int) -> Int {
        let extended = syntax.extendedLiterals
        // Valid literals: integer, numeric (`1.`, `1.5`, `.5`), real (`1e5`), and from 16 `0x1F` / `0o17` / `0b1`.
        let integerEnd = Self.isDigit(units[start]) ? endOfDigits(from: start, separators: extended) : nil
        if let integerEnd, peek(integerEnd) == 0x2E, peek(integerEnd + 1) == 0x2E { return integerEnd } // `1..2`
        var numericEnd: Int?
        if let integerEnd {
            if peek(integerEnd) == 0x2E {
                numericEnd = endOfDigits(from: integerEnd + 1, separators: extended) ?? integerEnd + 1
            }
        } else {
            numericEnd = endOfDigits(from: start + 1, separators: extended) // the caller saw a digit after `.`
        }
        let mantissaEnd = numericEnd ?? integerEnd ?? start + 1
        var realEnd: Int?
        var realFailEnd: Int?
        if let e = peek(mantissaEnd), e == 0x65 || e == 0x45 {
            var exponent = mantissaEnd + 1
            let signed = peek(exponent) == 0x2B || peek(exponent) == 0x2D
            if signed { exponent += 1 }
            if let end = endOfDigits(from: exponent, separators: extended) {
                realEnd = end
            } else if signed {
                realFailEnd = exponent // `1e+`: an error from 15 on; before, the server gives back `e+`
            }
        }
        var prefixedEnd: Int?
        var prefixFailEnd: Int?
        if extended, units[start] == 0x30, let radix = peek(start + 1).flatMap(Self.radix(prefix:)) {
            var end = start + 2
            while true {
                let digit = peek(end) == 0x5F ? end + 1 : end
                guard let unit = peek(digit), Self.isDigit(unit, radix: radix) else { break }
                end = digit + 1
            }
            if end > start + 2 { prefixedEnd = end } else { prefixFailEnd = peek(start + 2) == 0x5F ? start + 3 : start + 2 }
        }
        let literalEnd = max(realEnd ?? mantissaEnd, prefixedEnd ?? start)
        guard syntax.joinsTrailingWords else { return literalEnd }
        // From 15 on, a word right after any of these literals joins it (the server's longest match), and the failed forms
        // `1e+` / `0x` are tokens of their own.
        let junkEnd = { (literal: Int?) in literal.map { endOfWord(from: $0) } ?? start }
        return max(literalEnd, realFailEnd ?? start, prefixFailEnd ?? start,
                   junkEnd(integerEnd), junkEnd(numericEnd), junkEnd(realEnd), junkEnd(prefixedEnd))
    }

    /// End of a run of decimal digits starting at `index` (with `separators`, `_` only between two digits); `nil` when no
    /// digit is there.
    private func endOfDigits(from index: Int, separators: Bool) -> Int? {
        guard let first = peek(index), Self.isDigit(first) else { return nil }
        var end = index + 1
        while let unit = peek(end) {
            if Self.isDigit(unit) {
                end += 1
            } else if separators, unit == 0x5F, let next = peek(end + 1), Self.isDigit(next) {
                end += 2
            } else {
                break
            }
        }
        return end
    }

    /// 16, 8 or 2 for the letter after `0` in `0x`, `0o`, `0b` (either case).
    private static func radix(prefix unit: UInt16) -> Int? {
        switch unit {
        case 0x78, 0x58: 16
        case 0x6F, 0x4F: 8
        case 0x62, 0x42: 2
        default: nil
        }
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    private static func isDigit(_ unit: UInt16, radix: Int) -> Bool {
        switch radix {
        case 16: isHexDigit(unit)
        case 8: unit >= 0x30 && unit <= 0x37
        default: unit == 0x30 || unit == 0x31
        }
    }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == 0x24
    }

    /// `~ ! @ # % ^ & | ` ?`: an operator containing one of them may end in `+` or `-`.
    static func allowsTrailingSign(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x7E, 0x21, 0x40, 0x23, 0x25, 0x5E, 0x26, 0x7C, 0x60, 0x3F: true
        default: false
        }
    }

    static func isOperatorCharacter(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x3C, 0x3E, 0x3D, 0x7E, 0x21, 0x40, 0x23, 0x25, 0x5E, 0x26, 0x7C, 0x60, 0x3F: true
        default: false
        }
    }
}
