import Foundation

/// Maps PostgreSQL's ErrorResponse position (`P`: 1-based character index into the statement as sent, counting
/// code points) to a UTF-16 offset inside that statement, for the editor underline (design D13).
public enum SQLErrorLocator {
    /// UTF-16 offset of the character at `position`, clamped to the statement; nil for non-positive positions.
    public static func utf16Offset(in statement: String, position: Int) -> Int? {
        guard position >= 1 else { return nil }
        var remaining = position - 1
        var offset = 0
        for scalar in statement.unicodeScalars {
            if remaining == 0 { return offset }
            offset += scalar.utf16.count
            remaining -= 1
        }
        return offset
    }

    /// UTF-16 range of the token starting at the error position (one character when no token starts there).
    public static func highlightRange(in statement: String, position: Int) -> Range<Int>? {
        guard let start = utf16Offset(in: statement, position: position) else { return nil }
        let tokens = SQLLexer.tokenize(statement)
        if let token = tokens.first(where: { $0.range.lowerBound == start }) { return token.range }
        if let token = tokens.first(where: { $0.range.contains(start) }) { return token.range }
        let length = statement.utf16.count
        return start < length ? start..<(start + 1) : max(0, length - 1)..<length
    }
}
