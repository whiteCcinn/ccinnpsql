import Foundation

/// Bloat estimates from planner statistics (design D11). These follow the well-known approach of comparing
/// the actual page count with the pages the live tuples would need; they are estimates, not measurements.
public enum BloatEstimator {
    static let maxAlign = 8.0
    static let pageHeader = 24.0
    static let lineItem = 4.0
    static let heapTupleHeader = 23.0
    static let indexTupleHeader = 8.0
    static let btreeSpecial = 16.0

    /// Heap bloat. `nil` without statistics (never analyzed) or for empty tables.
    public static func table(pages: Int64?, tuples: Double?, columns: [ColumnInfo], blockSize: Int, fillFactor: Int? = nil) -> BloatEstimate? {
        guard let pages, pages > 0, let tuples, tuples >= 0, tuples.isFinite, blockSize >= 1_024, !columns.isEmpty,
              columns.allSatisfy({ $0.averageWidth != nil }) else { return nil }
        let hasNulls = columns.contains { ($0.nullFraction ?? 0) > 0 }
        let bitmap = hasNulls ? Double((columns.count + 7) / 8) : 0
        let header = alignUp(heapTupleHeader + bitmap)
        let data = columns.reduce(0.0) { $0 + Double($1.averageWidth ?? 0) * (1 - min(1, max(0, $1.nullFraction ?? 0))) }
        let tupleBytes = header + alignUp(data) + lineItem
        let fill = Double(min(100, max(10, fillFactor ?? 100))) / 100
        let usable = (Double(blockSize) - pageHeader) * fill
        let perPage = max(1, (usable / tupleBytes).rounded(.down))
        let expectedPages = (tuples / perPage).rounded(.up)
        return estimate(actualPages: pages, expectedPages: expectedPages, blockSize: blockSize)
    }

    /// B-tree index bloat; `nil` for other access methods, expression keys or missing statistics.
    public static func btreeIndex(_ index: IndexInfo, columns: [ColumnInfo], blockSize: Int) -> BloatEstimate? {
        guard index.method == "btree", let pages = index.pages, pages > 1, let tuples = index.estimatedTuples, tuples >= 0, tuples.isFinite,
              !index.columnNumbers.isEmpty, !index.columnNumbers.contains(0), blockSize >= 1_024 else { return nil }
        let byNumber = Dictionary(columns.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        var data = 0.0
        var nullable = false
        for number in index.columnNumbers {
            guard let column = byNumber[number], let width = column.averageWidth else { return nil }
            let nullFraction = min(1, max(0, column.nullFraction ?? 0))
            if nullFraction > 0 { nullable = true }
            data += Double(width) * (1 - nullFraction)
        }
        let tupleBytes = indexTupleHeader + (nullable ? 4 : 0) + alignUp(data) + lineItem
        let fill = Double(min(100, max(10, index.fillFactor ?? 90))) / 100
        let usable = (Double(blockSize) - pageHeader - btreeSpecial) * fill
        let perPage = max(1, (usable / tupleBytes).rounded(.down))
        let expectedPages = (tuples / perPage).rounded(.up) + 1 // metapage
        return estimate(actualPages: pages, expectedPages: expectedPages, blockSize: blockSize)
    }

    static func alignUp(_ value: Double) -> Double { (value / maxAlign).rounded(.up) * maxAlign }

    static func estimate(actualPages: Int64, expectedPages: Double, blockSize: Int) -> BloatEstimate? {
        guard expectedPages.isFinite, expectedPages >= 0, expectedPages < 9e15 else { return nil }
        let (actual, overflow) = actualPages.multipliedReportingOverflow(by: Int64(blockSize))
        guard !overflow else { return nil }
        let expected = Int64(expectedPages) &* Int64(blockSize)
        return BloatEstimate(actualBytes: actual, expectedBytes: min(expected, actual))
    }
}

/// Builds CREATE statements from catalog facts (PostgreSQL has no SHOW CREATE TABLE).
public enum DDLBuilder {
    public static func table(_ relation: RelationSummary, columns: [ColumnInfo], constraints: [ConstraintInfo], indexes: [IndexInfo],
                             triggers: [TriggerInfo], partitioning: PartitioningInfo?, options: [String]) -> String {
        var statements: [String] = []
        let persistence = relation.isUnlogged ? "UNLOGGED " : (relation.isTemporary ? "TEMPORARY " : "")
        let foreign = relation.kind == .foreignTable ? "FOREIGN " : ""
        if relation.isPartition, let parent = partitioning?.parent, let bound = relation.partitionBound {
            var text = "CREATE \(persistence)TABLE \(relation.qualifiedName) PARTITION OF \(parent)\n    \(bound)"
            if let key = partitioning?.partitionKey { text += "\n    PARTITION BY \(key)" }
            statements.append(text + ";")
        } else {
            var lines = columns.filter(\.isLocal).map(columnDefinition)
            for constraint in constraints where constraint.isLocal && constraint.kind != .notNull && constraint.kind != .trigger {
                lines.append("CONSTRAINT \(SQLText.identifier(constraint.name)) \(constraint.definition)")
            }
            var text = "CREATE \(persistence)\(foreign)TABLE \(relation.qualifiedName) (\n    " + lines.joined(separator: ",\n    ") + "\n)"
            if let key = partitioning?.partitionKey { text += "\nPARTITION BY \(key)" }
            if let parent = partitioning?.parent, !relation.isPartition { text += "\nINHERITS (\(parent))" }
            if !options.isEmpty { text += "\nWITH (\(options.joined(separator: ", ")))" }
            statements.append(text + ";")
        }
        for index in indexes where index.constraintName == nil {
            statements.append(terminated(index.definition))
        }
        for trigger in triggers {
            statements.append(terminated(trigger.definition))
        }
        statements.append(contentsOf: comments(relation, columns: columns))
        return statements.joined(separator: "\n\n") + "\n"
    }

    public static func view(_ relation: RelationSummary, definition: String, indexes: [IndexInfo] = []) -> String {
        let body = terminated(definition.trimmingCharacters(in: .whitespacesAndNewlines))
        var statements: [String]
        if relation.kind == .materializedView {
            statements = ["CREATE MATERIALIZED VIEW \(relation.qualifiedName) AS\n" + String(body.dropLast()) + "\nWITH DATA;"]
            statements.append(contentsOf: indexes.map { terminated($0.definition) })
        } else {
            statements = ["CREATE OR REPLACE VIEW \(relation.qualifiedName) AS\n" + body]
        }
        statements.append(contentsOf: comments(relation, columns: []))
        return statements.joined(separator: "\n\n") + "\n"
    }

    public static func sequence(_ relation: RelationSummary, info: SequenceInfo) -> String {
        var parts = ["CREATE SEQUENCE \(relation.qualifiedName)", "    AS \(info.dataType)"]
        if let increment = info.increment { parts.append("    INCREMENT BY \(increment)") }
        if let minValue = info.minValue { parts.append("    MINVALUE \(minValue)") }
        if let maxValue = info.maxValue { parts.append("    MAXVALUE \(maxValue)") }
        if let start = info.startValue { parts.append("    START WITH \(start)") }
        if let cache = info.cache { parts.append("    CACHE \(cache)") }
        parts.append(info.cycles ? "    CYCLE" : "    NO CYCLE")
        if let owner = info.ownedBy { parts.append("    OWNED BY \(owner)") }
        return parts.joined(separator: "\n") + ";\n"
    }

    static func columnDefinition(_ column: ColumnInfo) -> String {
        var text = "\(SQLText.identifier(column.name)) \(column.type)"
        if let collation = column.collation { text += " COLLATE \(SQLText.quoteIdentifier(collation))" }
        if let identity = column.identityDescription {
            text += " " + identity
        } else if let generated = column.generatedExpression {
            text += " GENERATED ALWAYS AS (\(generated)) STORED"
        } else if let defaultExpression = column.defaultExpression {
            text += " DEFAULT \(defaultExpression)"
        }
        if !column.isNullable { text += " NOT NULL" }
        return text
    }

    static func comments(_ relation: RelationSummary, columns: [ColumnInfo]) -> [String] {
        var statements: [String] = []
        let objectType: String = switch relation.kind {
        case .view: "VIEW"
        case .materializedView: "MATERIALIZED VIEW"
        case .foreignTable: "FOREIGN TABLE"
        case .sequence: "SEQUENCE"
        default: "TABLE"
        }
        if let comment = relation.comment, !comment.isEmpty {
            statements.append("COMMENT ON \(objectType) \(relation.qualifiedName) IS \(SQLText.literal(comment));")
        }
        for column in columns {
            if let comment = column.comment, !comment.isEmpty {
                statements.append("COMMENT ON COLUMN \(relation.qualifiedName).\(SQLText.identifier(column.name)) IS \(SQLText.literal(comment));")
            }
        }
        return statements
    }

    static func terminated(_ statement: String) -> String {
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text.removeLast() }
        return text + ";"
    }
}
