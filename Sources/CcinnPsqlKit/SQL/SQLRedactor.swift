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
