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

/// Tokenizer for PostgreSQL SQL (design D12). Never fails: unterminated strings and comments extend to the end
/// of the input, unknown characters become operators. Linear time over UTF-16 code units; nested block comments
/// and dollar quotes are understood, so keywords inside strings, comments and function bodies are never seen.
public struct SQLLexer: Sendable {
    public let units: [UInt16]

    public init(_ text: String) {
        units = Array(text.utf16)
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

    /// Upper-cased word for keywords/identifiers, raw text otherwise.
    public func word(of token: SQLToken) -> String {
        token.kind == .keyword || token.kind == .identifier ? text(of: token).uppercased() : text(of: token)
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
                index = endOfQuoted(from: index, quote: 0x27, backslashEscapes: false)
                tokens.append(SQLToken(kind: .string, range: start..<index))
            case 0x22: // "
                index = endOfQuoted(from: index, quote: 0x22, backslashEscapes: false)
                tokens.append(SQLToken(kind: .quotedIdentifier, range: start..<index))
            case 0x24: // $
                if let digitsEnd = parameterEnd(from: index) {
                    index = digitsEnd
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
            case 0x2E where peek(index + 1).map(Self.isDigit) == true && !isMemberAccess(tokens, at: index):
                index = endOfNumber(from: index)
                tokens.append(SQLToken(kind: .number, range: start..<index))
            case 0x28, 0x29, 0x2C, 0x3B, 0x2E, 0x5B, 0x5D: // ( ) , ; . [ ]
                index += 1
                tokens.append(SQLToken(kind: .punctuation, range: start..<index))
            default:
                if let prefixed = prefixedLiteral(at: index) {
                    index = prefixed.end
                    tokens.append(SQLToken(kind: prefixed.kind, range: start..<index))
                } else if Self.isIdentifierStart(unit) {
                    while index < count, Self.isIdentifierPart(units[index]) { index += 1 }
                    let word = String(decoding: units[start..<index], as: UTF16.self).uppercased()
                    let kind: SQLToken.Kind = SQLKeywords.all.contains(word) ? .keyword : .identifier
                    tokens.append(SQLToken(kind: kind, range: start..<index))
                } else {
                    index += 1
                    // PostgreSQL operators are runs of + - * / < > = ~ ! @ # % ^ & | ` ? (and `::`, `:=`).
                    if Self.isOperatorCharacter(unit) {
                        while index < count, Self.isOperatorCharacter(units[index]), index - start < 63,
                              !(units[index] == 0x2D && peek(index + 1) == 0x2D),
                              !(units[index] == 0x2F && peek(index + 1) == 0x2A) {
                            index += 1
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

    /// `t.5` is member access, `.5` alone is a number.
    private func isMemberAccess(_ tokens: [SQLToken], at index: Int) -> Bool {
        guard let last = tokens.last, last.range.upperBound == index else { return false }
        return last.kind == .identifier || last.kind == .quotedIdentifier || last.kind == .keyword
    }

    private func endOfLine(from index: Int) -> Int {
        var index = index
        while index < units.count, units[index] != 0x0A, units[index] != 0x0D { index += 1 }
        return index
    }

    private func endOfBlockComment(from index: Int) -> Int {
        var depth = 0
        var index = index
        while index < units.count {
            if units[index] == 0x2F, peek(index + 1) == 0x2A {
                depth += 1
                index += 2
            } else if units[index] == 0x2A, peek(index + 1) == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return units.count
    }

    private func endOfQuoted(from index: Int, quote: UInt16, backslashEscapes: Bool) -> Int {
        var index = index + 1
        while index < units.count {
            let unit = units[index]
            if backslashEscapes, unit == 0x5C {
                index += 2
                continue
            }
            if unit == quote {
                if peek(index + 1) == quote {
                    index += 2
                    continue
                }
                return index + 1
            }
            index += 1
        }
        return units.count
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
        let tag = units[start..<tagEnd]
        var index = tagEnd
        while index + tag.count <= units.count {
            if units[index] == 0x24, units[index..<(index + tag.count)].elementsEqual(tag) { return index + tag.count }
            index += 1
        }
        return units.count
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
            return (endOfQuoted(from: index + 1, quote: 0x27, backslashEscapes: false), .string)
        case 0x55, 0x75: // U&
            guard peek(index + 1) == 0x26, let quote = peek(index + 2), quote == 0x27 || quote == 0x22 else { return nil }
            return (endOfQuoted(from: index + 2, quote: quote, backslashEscapes: false), quote == 0x27 ? .string : .quotedIdentifier)
        default:
            return nil
        }
    }

    private func endOfNumber(from index: Int) -> Int {
        var index = index
        if units[index] == 0x30, let next = peek(index + 1), [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(next) { // 0x 0o 0b
            index += 2
            while index < units.count, Self.isHexDigit(units[index]) || units[index] == 0x5F { index += 1 }
            return index
        }
        while index < units.count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
        if peek(index) == 0x2E, peek(index + 1) != 0x2E { // not a `..` range
            index += 1
            while index < units.count, Self.isDigit(units[index]) || units[index] == 0x5F { index += 1 }
        }
        if let e = peek(index), e == 0x65 || e == 0x45 {
            var lookahead = index + 1
            if let sign = peek(lookahead), sign == 0x2B || sign == 0x2D { lookahead += 1 }
            if let digit = peek(lookahead), Self.isDigit(digit) {
                index = lookahead
                while index < units.count, Self.isDigit(units[index]) { index += 1 }
            }
        }
        return index
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

    static func isHexDigit(_ unit: UInt16) -> Bool {
        isDigit(unit) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F || unit >= 0x80
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit) || unit == 0x24
    }

    static func isOperatorCharacter(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x2B, 0x2D, 0x2A, 0x2F, 0x3C, 0x3E, 0x3D, 0x7E, 0x21, 0x40, 0x23, 0x25, 0x5E, 0x26, 0x7C, 0x60, 0x3F: true
        default: false
        }
    }
}
