import Foundation

/// Removes credentials from SQL before it is written to history or audit logs (CcinnStarRocks review lesson):
/// string literals after `PASSWORD` (CREATE/ALTER ROLE/USER, user mappings), values of credential-like options
/// (`OPTIONS (password '…', aws_secret_access_key '…')`, `SET app.secret = '…'`), and passwords inside
/// connection strings (`'host=… password=…'`, `postgresql://user:pass@host`) become `***`.
public enum SQLRedactor {
    static let sensitiveKeyFragments = ["password", "passwd", "secret", "access_key", "accesskey", "token", "credential",
                                        "private_key", "privatekey", "api_key", "apikey"]

    public static func redact(_ sql: String) -> String {
        let lexer = SQLLexer(sql)
        let tokens = lexer.tokens().filter { $0.kind != .comment }
        var replacements: [(Range<Int>, String)] = []
        for (index, token) in tokens.enumerated() where token.kind == .string {
            if isSecretLiteral(at: index, tokens: tokens, lexer: lexer) {
                replacements.append((token.range, quoted("***", like: lexer.text(of: token))))
            } else {
                let text = lexer.text(of: token)
                let cleaned = redactConnectionString(text)
                if cleaned != text { replacements.append((token.range, cleaned)) }
            }
        }
        guard !replacements.isEmpty else { return sql }
        var units = lexer.units
        for (range, replacement) in replacements.reversed() {
            units.replaceSubrange(range, with: Array(replacement.utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Other sessions' SQL as the MCP tools return it: every string and numeric literal becomes `?` (digest style) and
    /// comments are removed, so no literal of another session reaches the AI (a secret is not always next to PASSWORD).
    /// Literals are taken from both readings of standard_conforming_strings, so a backslash before a quote cannot end a
    /// literal early and leak its rest. Parameters (`$1`), names and keywords stay.
    public static func digest(_ sql: String) -> String {
        let units = Array(sql.utf16)
        var literals: [Range<Int>] = []
        var comments: [Range<Int>] = []
        for syntax in [SQLLexer.Syntax.editor, SQLLexer.Syntax.editor.with(standardConformingStrings: false)] {
            for token in SQLLexer(sql, syntax: syntax).tokens() {
                switch token.kind {
                case .string, .number: literals.append(token.range)
                case .comment: comments.append(token.range)
                default: break
                }
            }
        }
        let literalSpans = merged(literals)
        // A comment that overlaps a literal of the other reading is part of that literal.
        let commentSpans = merged(comments).filter { comment in !literalSpans.contains { $0.overlaps(comment) } }
        let spans = (literalSpans.map { ($0, true) } + commentSpans.map { ($0, false) }).sorted { $0.0.lowerBound < $1.0.lowerBound }
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        var cursor = 0
        for (span, isLiteral) in spans where span.lowerBound >= cursor {
            output.append(contentsOf: units[cursor..<span.lowerBound])
            if isLiteral {
                output.append(0x3F) // ?
            } else if span.upperBound >= units.count || [0x20, 0x09, 0x0A, 0x0D].contains(units[span.upperBound]) {
                while let last = output.last, last == 0x20 || last == 0x09 { output.removeLast() }
            }
            cursor = span.upperBound
        }
        if cursor < units.count { output.append(contentsOf: units[cursor...]) }
        return String(decoding: output, as: UTF16.self)
    }

    /// Overlapping or touching ranges joined, in order.
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    static func isSecretLiteral(at index: Int, tokens: [SQLToken], lexer: SQLLexer) -> Bool {
        func word(_ offset: Int) -> String? {
            let position = index + offset
            guard tokens.indices.contains(position) else { return nil }
            return lexer.text(of: tokens[position]).uppercased()
        }
        // PASSWORD '…' / ENCRYPTED PASSWORD '…' / PASSWORD = '…' (also as an OPTIONS key)
        if word(-1) == "PASSWORD" || (word(-1) == "=" && word(-2) == "PASSWORD") { return true }
        // credential-like key followed by a value: OPTIONS (secret_key '…'), SET app.secret = '…', 'key' = '…'
        var keyIndex = index - 1
        if let previous = word(-1), previous == "=" || previous == "TO" { keyIndex -= 1 }
        guard tokens.indices.contains(keyIndex) else { return false }
        let keyToken = tokens[keyIndex]
        guard keyToken.kind == .identifier || keyToken.kind == .keyword || keyToken.kind == .quotedIdentifier || keyToken.kind == .string else {
            return false
        }
        let key = lexer.text(of: keyToken).lowercased()
        return sensitiveKeyFragments.contains { key.contains($0) }
    }

    /// `password=…` inside libpq connection strings and `user:password@` inside URIs.
    static func redactConnectionString(_ literal: String) -> String {
        var text = literal
        if let regex = try? Regex("(?i)(password\\s*=\\s*)('[^']*'|[^\\s']+)") {
            text = text.replacing(regex) { match in
                String(match.output[1].substring ?? "") + "***"
            }
        }
        if let uri = try? Regex("(?i)(postgres(?:ql)?://[^:/@\\s]+:)([^@\\s]+)(@)") {
            text = text.replacing(uri) { match in
                String(match.output[1].substring ?? "") + "***" + String(match.output[3].substring ?? "")
            }
        }
        return text
    }

    static func quoted(_ value: String, like literal: String) -> String {
        if literal.hasPrefix("$") {
            let tagEnd = literal.dropFirst().firstIndex(of: "$").map { literal.index(after: $0) } ?? literal.index(after: literal.startIndex)
            let tag = String(literal[..<tagEnd])
            return tag + value + tag
        }
        var prefix = ""
        for character in literal {
            if character == "'" { break }
            prefix.append(character)
        }
        return prefix + "'" + value + "'"
    }
}
