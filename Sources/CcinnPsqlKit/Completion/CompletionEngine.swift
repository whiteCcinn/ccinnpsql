import Foundation
import PostgresKit

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: Int, Sendable, Hashable {
        case column, alias, table, view, materializedView, foreignTable, sequence, schema, function, type, keyword
    }

    public let kind: Kind
    public let label: String
    public let insertText: String
    /// Secondary text: column type and table, function signature, object kind.
    public let detail: String?

    public var id: String { "\(kind.rawValue)\u{1F}\(label)\u{1F}\(detail ?? "")" }
}

public struct CompletionResult: Sendable {
    /// UTF-16 range in the editor text that the chosen item replaces.
    public let replacementRange: Range<Int>
    public let prefix: String
    public let items: [CompletionItem]
    /// Tables referenced by the statement whose columns are not in the snapshot yet; the app loads
    /// them and asks again.
    public let missingColumns: [TableKey]
    /// Schemas whose object lists are needed but not loaded yet.
    public let missingSchemas: [String]
    /// The cursor is where a relation or schema name must follow (`FROM `, `JOIN `, `TRUNCATE `, `SET search_path TO `, …),
    /// so the editor may offer the list before anything is typed.
    public let expectsObjectName: Bool

    public init(replacementRange: Range<Int>, prefix: String, items: [CompletionItem], missingColumns: [TableKey] = [],
                missingSchemas: [String] = [], expectsObjectName: Bool = false) {
        self.replacementRange = replacementRange
        self.prefix = prefix
        self.items = items
        self.missingColumns = missingColumns
        self.missingSchemas = missingSchemas
        self.expectsObjectName = expectsObjectName
    }

    public var needsMoreSchema: Bool { !missingColumns.isEmpty || !missingSchemas.isEmpty }

    public static func empty(at cursor: Int) -> CompletionResult {
        CompletionResult(replacementRange: cursor..<cursor, prefix: "", items: [])
    }
}

/// Context-aware PostgreSQL completion (design D12). Pure and synchronous; callers run it off the main actor.
public enum CompletionEngine {
    public static let defaultLimit = 200

    enum Context: Equatable {
        case statementStart
        case showTarget
        case tableName(materializedViewsOnly: Bool)
        case afterTableReference
        case schema
        case typeName
        case expression

        /// Only a relation or schema name can follow, so the list is worth offering before anything is typed.
        var expectsObjectName: Bool {
            switch self {
            case .tableName, .schema: true
            case .statementStart, .showTarget, .afterTableReference, .typeName, .expression: false
            }
        }
    }

    /// A table reference in scope: a base table (schema + name) or a derived table/CTE with known columns.
    struct ScopeTable {
        var alias: String?
        var schema: String?
        var table: String
        var derivedColumns: [String]?
    }

    public static func complete(text: String, cursor: Int, schema: SchemaSnapshot, limit: Int = defaultLimit) -> CompletionResult {
        let lexer = SQLLexer(text)
        let cursor = max(0, min(cursor, lexer.units.count))
        let allTokens = lexer.tokens()

        // Restrict to the statement around the cursor.
        let isSemicolon: (SQLToken) -> Bool = { $0.kind == .punctuation && lexer.units[$0.range.lowerBound] == 0x3B }
        let statementStart = allTokens.last { isSemicolon($0) && $0.range.upperBound <= cursor }?.range.upperBound ?? 0
        let statementEnd = allTokens.first { isSemicolon($0) && $0.range.lowerBound >= cursor }?.range.lowerBound ?? lexer.units.count
        let tokens = allTokens.filter { $0.range.lowerBound >= statementStart && $0.range.upperBound <= statementEnd }

        // No completion inside strings or comments.
        if let enclosing = tokens.first(where: { $0.range.lowerBound < cursor && cursor < $0.range.upperBound }),
           enclosing.kind == .string || enclosing.kind == .comment {
            return .empty(at: cursor)
        }
        if let ending = tokens.last(where: { $0.range.upperBound == cursor }) {
            if ending.kind == .comment, lexer.text(of: ending).hasPrefix("--") || !lexer.text(of: ending).hasSuffix("*/") {
                return .empty(at: cursor)
            }
            if ending.kind == .string, !isTerminated(ending, lexer: lexer) { return .empty(at: cursor) }
        }

        let prefixToken = tokens.last {
            $0.range.upperBound == cursor && ($0.kind == .identifier || $0.kind == .keyword || $0.kind == .quotedIdentifier)
        }
        let replacementStart = prefixToken?.range.lowerBound ?? cursor
        let prefix: String = prefixToken.map { token in
            token.kind == .quotedIdentifier ? lexer.identifierValue(of: token) : lexer.text(of: token)
        } ?? ""
        let before = tokens.filter { $0.range.upperBound <= replacementStart && $0.kind != .comment }
        let significant = tokens.filter { $0.kind != .comment }
        let scope = scopeTables(tokens: significant, lexer: lexer, schema: schema)

        var candidates: [CompletionItem]
        var missing: [TableKey] = []
        var missingSchemas: [String] = []
        var expectsObjectName = false
        if let last = before.last, isDot(last, lexer) {
            let qualifier = qualifierChain(before: before, lexer: lexer)
            // The clause before `schema.` decides what may follow (only materialized views after REFRESH …, no functions after FROM).
            let context = clauseContext(before: Array(before.dropLast(qualifier.count * 2)), lexer: lexer)
            (candidates, missing) = memberCandidates(qualifier: qualifier, scope: scope, schema: schema, context: context)
            if let schemaName = qualifier.first, qualifier.count == 1, schema.isSchema(schemaName), schema.objects(in: schemaName) == nil {
                missingSchemas.append(schemaName)
            }
        } else {
            let context = clauseContext(before: before, lexer: lexer)
            (candidates, missing) = contextCandidates(context, scope: scope, schema: schema)
            if case .tableName = context {
                missingSchemas += schema.searchPath.filter { schema.isSchema($0) && schema.objects(in: $0) == nil }
            }
            expectsObjectName = context.expectsObjectName
        }
        let ranked = rank(candidates, prefix: prefix, limit: limit)
        return CompletionResult(replacementRange: replacementStart..<cursor, prefix: prefix, items: ranked,
                                missingColumns: missing, missingSchemas: missingSchemas, expectsObjectName: expectsObjectName)
    }

    // MARK: Scope analysis

    static func isDot(_ token: SQLToken, _ lexer: SQLLexer) -> Bool {
        token.kind == .punctuation && lexer.units[token.range.lowerBound] == 0x2E
    }

    static func isTerminated(_ token: SQLToken, lexer: SQLLexer) -> Bool {
        let text = lexer.text(of: token)
        guard text.count >= 2 else { return false }
        if text.hasPrefix("$") { return text.hasSuffix("$") && text.dropFirst().contains("$") && text.count > 2 }
        return text.hasSuffix("'") && text.filter({ $0 == "'" }).count % 2 == 0
    }

    static func isName(_ token: SQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier || token.kind == .keyword
    }

    /// `a.b.` before the cursor → ["a", "b"].
    static func qualifierChain(before: [SQLToken], lexer: SQLLexer) -> [String] {
        var parts: [String] = []
        var index = before.count - 1
        while index >= 1, isDot(before[index], lexer), isName(before[index - 1]),
              before[index - 1].range.upperBound == before[index].range.lowerBound {
            parts.insert(lexer.identifierValue(of: before[index - 1]), at: 0)
            index -= 2
        }
        return parts
    }

    static let aliasStopWords: Set<String> = SQLKeywords.reserved.union([
        "LATERAL", "WINDOW", "OUTER", "INNER", "LIMIT", "WHERE", "ON", "USING", "ONLY", "TABLESAMPLE", "SET", "RETURNING", "VALUES",
        "NATURAL", "CROSS", "FULL", "LEFT", "RIGHT", "JOIN", "GROUP", "ORDER", "HAVING", "OFFSET", "FETCH", "FOR", "UNION",
    ])

    /// Tables, derived tables and CTEs referenced anywhere in the statement, with their aliases.
    static func scopeTables(tokens: [SQLToken], lexer: SQLLexer, schema: SchemaSnapshot) -> [ScopeTable] {
        var result: [ScopeTable] = []
        var ctes: [String: [String]] = [:]
        let words = tokens.map { $0.kind == .keyword ? lexer.text(of: $0).uppercased() : "" }

        // CTEs: WITH name AS ( … ), name AS ( … )
        if words.first == "WITH" {
            var index = 1
            if index < words.count, words[index] == "RECURSIVE" { index += 1 }
            while index + 2 < tokens.count, isName(tokens[index]), words[index + 1] == "AS",
                  lexer.text(of: tokens[index + 2]) == "(" {
                let name = lexer.identifierValue(of: tokens[index])
                let close = matchingParen(tokens: tokens, open: index + 2, lexer: lexer)
                ctes[name.lowercased()] = derivedColumns(tokens: Array(tokens[(index + 3)..<close]), lexer: lexer)
                index = close + 1
                if index < tokens.count, lexer.text(of: tokens[index]) == "," { index += 1 } else { break }
            }
        }

        var index = 0
        while index < tokens.count {
            let word = words[index]
            let startsReference = ["FROM", "JOIN", "UPDATE", "INTO", "TABLE"].contains(word)
            index += 1
            guard startsReference else { continue }
            while index < tokens.count, words[index] == "ONLY" || words[index] == "LATERAL" { index += 1 }
            var parsingList = true
            while parsingList, index < tokens.count {
                parsingList = false
                if lexer.text(of: tokens[index]) == "(" {
                    // Derived table: ( SELECT … ) [AS] alias
                    let close = matchingParen(tokens: tokens, open: index, lexer: lexer)
                    let columns = derivedColumns(tokens: Array(tokens[(index + 1)..<min(close, tokens.count)]), lexer: lexer)
                    index = close + 1
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        result.append(ScopeTable(alias: alias, schema: nil, table: alias, derivedColumns: columns))
                        index = next
                    }
                } else if isName(tokens[index]), !aliasStopWords.contains(words[index]) || tokens[index].kind != .keyword {
                    var parts = [lexer.identifierValue(of: tokens[index])]
                    index += 1
                    while index + 1 < tokens.count, isDot(tokens[index], lexer), isName(tokens[index + 1]) {
                        parts.append(lexer.identifierValue(of: tokens[index + 1]))
                        index += 2
                    }
                    let table = parts[parts.count - 1]
                    let schemaName = parts.count >= 2 ? parts[parts.count - 2] : nil
                    var reference = ScopeTable(alias: nil, schema: schemaName, table: table, derivedColumns: nil)
                    if schemaName == nil, let cteColumns = ctes[table.lowercased()] { reference.derivedColumns = cteColumns }
                    if let (alias, next) = parseAlias(tokens: tokens, words: words, at: index, lexer: lexer) {
                        reference.alias = alias
                        index = next
                    }
                    result.append(reference)
                }
                if index < tokens.count, lexer.text(of: tokens[index]) == ",", word == "FROM" {
                    index += 1
                    parsingList = true
                }
            }
        }
        return result
    }

    static func parseAlias(tokens: [SQLToken], words: [String], at index: Int, lexer: SQLLexer) -> (String, Int)? {
        var index = index
        if index < tokens.count, words[index] == "AS" { index += 1 }
        guard index < tokens.count, isName(tokens[index]) else { return nil }
        if tokens[index].kind == .keyword, aliasStopWords.contains(words[index]) { return nil }
        return (lexer.identifierValue(of: tokens[index]), index + 1)
    }

    static func matchingParen(tokens: [SQLToken], open: Int, lexer: SQLLexer) -> Int {
        var depth = 0
        var index = open
        while index < tokens.count {
            let text = lexer.text(of: tokens[index])
            if tokens[index].kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            index += 1
        }
        return tokens.count
    }

    /// Output column names of `SELECT a, b AS c, t.d, count(*) AS n FROM …`.
    static func derivedColumns(tokens: [SQLToken], lexer: SQLLexer) -> [String] {
        guard let selectIndex = tokens.firstIndex(where: { lexer.text(of: $0).uppercased() == "SELECT" }) else { return [] }
        var columns: [String] = []
        var depth = 0
        var item: [SQLToken] = []
        // The output name is the item's last identifier: `b AS c` → c, `t.d` → d, `count(*) n` → n.
        func flushItem() {
            defer { item.removeAll() }
            guard let last = item.last, isName(last) else { return }
            columns.append(lexer.identifierValue(of: last))
        }
        for token in tokens[(selectIndex + 1)...] {
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == "(" { depth += 1 }
                if text == ")" { depth -= 1 }
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "FROM" { break }
            if depth == 0, text == "," {
                flushItem()
                continue
            }
            if depth == 0, token.kind == .keyword, text.uppercased() == "DISTINCT", item.isEmpty { continue }
            item.append(token)
        }
        flushItem()
        return columns
    }

    // MARK: Clause context

    static func clauseContext(before: [SQLToken], lexer: SQLLexer) -> Context {
        guard !before.isEmpty else { return .statementStart }
        let words = before.map { $0.kind == .keyword || $0.kind == .identifier ? lexer.text(of: $0).uppercased() : "" }
        let lastText = lexer.text(of: before[before.count - 1]).uppercased()

        if lastText == "SHOW" { return .showTarget }
        if lastText == "::" { return .typeName }
        if lastText == "SCHEMA" { return .schema }
        if words.count >= 2, words[words.count - 2] == "SEARCH_PATH", lastText == "TO" || lastText == "=" { return .schema }
        if words.suffix(2) == ["MATERIALIZED", "VIEW"] || words.suffix(3) == ["MATERIALIZED", "VIEW", "CONCURRENTLY"] {
            return .tableName(materializedViewsOnly: true)
        }

        // Walk back within the current parenthesis level to the nearest clause keyword.
        var depth = 0
        var distance = 0
        var sawComma = false
        for index in stride(from: before.count - 1, through: 0, by: -1) {
            let token = before[index]
            let text = lexer.text(of: token)
            if token.kind == .punctuation {
                if text == ")" { depth += 1 }
                if text == "(" {
                    if depth == 0 { return .expression } // inside a function call or subquery start
                    depth -= 1
                }
                if depth == 0, text == ",", distance == 0 { sawComma = true }
            }
            guard depth == 0 else { continue }
            let word = words[index]
            switch word {
            case "ONLY" where index == 0 || !["FROM", "JOIN", "UPDATE", "TABLE", "TRUNCATE", "EXISTS"].contains(words[index - 1]):
                break // `FETCH FIRST n ROWS ONLY` ends a query; only `FROM ONLY t`, `ALTER TABLE ONLY t`, … name a table.
            case "FROM", "JOIN", "UPDATE", "INTO", "TABLE", "TRUNCATE", "ONLY", "LATERAL":
                if distance == 0 || sawComma { return .tableName(materializedViewsOnly: false) }
                return word == "UPDATE" || word == "INTO" || word == "TABLE" || word == "TRUNCATE" ? .expression : .afterTableReference
            case "SELECT", "WHERE", "ON", "HAVING", "BY", "SET", "AND", "OR", "NOT", "WHEN", "THEN", "ELSE", "CASE", "DISTINCT", "IN",
                 "LIKE", "ILIKE", "BETWEEN", "IS", "USING", "OVER", "PARTITION", "VALUES", "RETURNING", "FILTER":
                return .expression
            default:
                break
            }
            if token.kind == .operator { return .expression }
            if token.kind != .punctuation || text != "." { distance += 1 }
        }
        return .expression
    }

    // MARK: Candidates

    static func memberCandidates(qualifier: [String], scope: [ScopeTable], schema: SchemaSnapshot,
                                 context: Context = .expression) -> ([CompletionItem], [TableKey]) {
        guard let head = qualifier.first else { return ([], []) }
        switch qualifier.count {
        case 1:
            if schema.isSchema(head), case let .tableName(materializedViewsOnly) = context {
                return (objectCandidates(schemaName: head, schema: schema, materializedViewsOnly: materializedViewsOnly), [])
            }
            // Precedence: explicit alias, schema name, table referenced without alias, table on the search path.
            if let table = scope.first(where: { $0.alias?.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if schema.isSchema(head) {
                return (objectCandidates(schemaName: head, schema: schema, materializedViewsOnly: false)
                        + functionCandidates(schemas: [head], schema: schema), [])
            }
            if let table = scope.first(where: { $0.alias == nil && $0.table.caseInsensitiveCompare(head) == .orderedSame }) {
                return columnCandidates(of: [table], schema: schema)
            }
            if let resolved = schema.resolveSchema(of: head) {
                return columnCandidates(of: [ScopeTable(alias: nil, schema: resolved, table: head, derivedColumns: nil)], schema: schema)
            }
            return ([], [])
        default:
            return columnCandidates(of: [ScopeTable(alias: nil, schema: qualifier[qualifier.count - 2],
                                                    table: qualifier[qualifier.count - 1], derivedColumns: nil)], schema: schema)
        }
    }

    static func contextCandidates(_ context: Context, scope: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        switch context {
        case .statementStart:
            return (SQLKeywords.statementStarters.map(keywordItem), [])
        case .showTarget:
            return (SQLKeywords.showTargets.map(keywordItem), [])
        case .schema:
            return (schemaCandidates(schema), [])
        case .typeName:
            return (SQLKeywords.types.map { CompletionItem(kind: .type, label: $0, insertText: $0, detail: "type") }, [])
        case let .tableName(materializedViewsOnly):
            var items: [CompletionItem] = []
            for schemaName in schema.searchPath {
                items += objectCandidates(schemaName: schemaName, schema: schema, materializedViewsOnly: materializedViewsOnly)
            }
            items += schemaCandidates(schema)
            return (items, [])
        case .afterTableReference:
            let keywords = ["WHERE", "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "FULL OUTER JOIN", "CROSS JOIN", "LATERAL",
                            "ON", "USING", "AS", "GROUP BY", "ORDER BY", "HAVING", "LIMIT", "UNION ALL", "TABLESAMPLE", "WINDOW"]
            return (keywords.map(keywordItem), [])
        case .expression:
            let (columns, missing) = columnCandidates(of: scope, schema: schema)
            let aliases = scope.compactMap(\.alias).map {
                CompletionItem(kind: .alias, label: $0, insertText: quoteIfNeeded($0), detail: "alias")
            }
            let builtins = SQLFunctions.all.map {
                CompletionItem(kind: .function, label: $0.name, insertText: $0.name + "(", detail: $0.signature)
            }
            return (columns + aliases + functionCandidates(schemas: schema.searchPath, schema: schema) + builtins
                    + SQLKeywords.clauseKeywords.map(keywordItem), missing)
        }
    }

    static func columnCandidates(of tables: [ScopeTable], schema: SchemaSnapshot) -> ([CompletionItem], [TableKey]) {
        var items: [CompletionItem] = []
        var missing: [TableKey] = []
        var seen = Set<String>()
        for table in tables {
            let source = table.alias ?? table.table
            if let derived = table.derivedColumns {
                for column in derived where seen.insert("\(source).\(column)").inserted {
                    items.append(CompletionItem(kind: .column, label: column, insertText: quoteIfNeeded(column), detail: source))
                }
                continue
            }
            guard let schemaName = table.schema ?? schema.resolveSchema(of: table.table) ?? schema.currentSchema else { continue }
            guard let columns = schema.columns(schema: schemaName, table: table.table) else {
                if schema.object(named: table.table, in: schemaName) != nil || table.schema != nil {
                    missing.append(TableKey(schema: schemaName, table: table.table))
                }
                continue
            }
            for column in columns where seen.insert("\(source).\(column.name)").inserted {
                items.append(CompletionItem(kind: .column, label: column.name, insertText: quoteIfNeeded(column.name),
                                            detail: "\(column.type) · \(table.table)"))
            }
        }
        return (items, missing)
    }

    static func objectCandidates(schemaName: String, schema: SchemaSnapshot, materializedViewsOnly: Bool) -> [CompletionItem] {
        (schema.objects(in: schemaName) ?? []).compactMap { object in
            let kind: CompletionItem.Kind
            switch object.kind {
            case .table, .partitionedTable: kind = .table
            case .view: kind = .view
            case .materializedView: kind = .materializedView
            case .foreignTable: kind = .foreignTable
            case .sequence: kind = .sequence
            }
            if materializedViewsOnly, kind != .materializedView { return nil }
            if object.kind == .sequence, !materializedViewsOnly { return nil }
            return CompletionItem(kind: kind, label: object.name, insertText: quoteIfNeeded(object.name),
                                  detail: "\(object.kind.displayName) · \(schemaName)")
        }
    }

    static func functionCandidates(schemas: [String], schema: SchemaSnapshot) -> [CompletionItem] {
        schemas.flatMap { name in
            (schema.functionsBySchema[name.lowercased()] ?? []).filter { $0.kind != .procedure }.map {
                CompletionItem(kind: .function, label: $0.name, insertText: quoteIfNeeded($0.name) + "(", detail: "\($0.signature) · \(name)")
            }
        }
    }

    static func schemaCandidates(_ schema: SchemaSnapshot) -> [CompletionItem] {
        schema.schemas.map { CompletionItem(kind: .schema, label: $0, insertText: quoteIfNeeded($0), detail: "schema") }
    }

    static func keywordItem(_ keyword: String) -> CompletionItem {
        CompletionItem(kind: .keyword, label: keyword, insertText: keyword, detail: nil)
    }

    /// Double-quotes identifiers that are reserved words or not plain lower-case names.
    public static func quoteIfNeeded(_ name: String) -> String {
        SQLText.identifier(name)
    }

    // MARK: Ranking

    /// Prefix matches first, then word-boundary matches (`cd` → `city_daily`), then subsequences.
    static func rank(_ items: [CompletionItem], prefix: String, limit: Int) -> [CompletionItem] {
        let needle = prefix.lowercased()
        var scored: [(item: CompletionItem, score: Int)] = []
        scored.reserveCapacity(items.count)
        var seen = Set<String>()
        for item in items where seen.insert(item.id).inserted {
            let score = matchScore(label: item.label.lowercased(), needle: needle)
            if score > 0 { scored.append((item, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.item.kind != rhs.item.kind { return lhs.item.kind.rawValue < rhs.item.kind.rawValue }
            return lhs.item.label.localizedStandardCompare(rhs.item.label) == .orderedAscending
        }
        return scored.prefix(max(0, limit)).map(\.item)
    }

    static func matchScore(label: String, needle: String) -> Int {
        if needle.isEmpty { return 1 }
        if label == needle { return 5 }
        if label.hasPrefix(needle) { return 4 }
        let words = label.split(whereSeparator: { $0 == "_" || $0 == " " || $0 == "." })
        if words.dropFirst().contains(where: { $0.hasPrefix(needle) }) { return 3 }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(needle) { return 2 }
        var remaining = Substring(needle)
        for character in label where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 1 }
        }
        return 0
    }
}
