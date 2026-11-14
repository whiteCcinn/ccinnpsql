import Foundation

/// One node of an `EXPLAIN (FORMAT JSON)` plan with derived metrics.
public struct PlanNode: Sendable, Identifiable, Hashable {
    public let id: Int
    public let nodeType: String
    public let relation: String?
    public let alias: String?
    public let indexName: String?
    public let joinType: String?
    public let strategy: String?
    public let parentRelationship: String?
    public let startupCost: Double?
    public let totalCost: Double?
    public let planRows: Double?
    public let planWidth: Double?
    public let actualStartupTime: Double?
    public let actualTotalTime: Double?
    public let actualRows: Double?
    public let actualLoops: Double?
    public let sharedHitBlocks: Double?
    public let sharedReadBlocks: Double?
    public let tempReadBlocks: Double?
    public let tempWrittenBlocks: Double?
    public let rowsRemovedByFilter: Double?
    public let workersPlanned: Double?
    public let workersLaunched: Double?
    /// Conditions and other notable properties (`Filter`, `Index Cond`, `Hash Cond`, `Sort Key`, …).
    public let details: [PlanDetail]
    public let children: [PlanNode]
    /// Milliseconds spent in this node excluding its children (total time × loops − children), when ANALYZE ran.
    public let exclusiveTime: Double?

    public var title: String {
        var text = nodeType
        if let joinType, nodeType.contains("Join") || nodeType == "Nested Loop" { text = "\(joinType) \(text)" }
        if let strategy, nodeType == "Aggregate" { text = "\(strategy) \(text)" }
        return text
    }

    /// `on orders o` / `using idx on orders`.
    public var subtitle: String? {
        var parts: [String] = []
        if let indexName { parts.append("using \(indexName)") }
        if let relation {
            parts.append("on \(relation)" + (alias.map { $0 != relation ? " \($0)" : "" } ?? ""))
        } else if let alias, nodeType.contains("Scan") {
            parts.append("on \(alias)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Actual rows per loop over planned rows (or the inverse), ≥ 1; nil without ANALYZE.
    public var estimateFactor: Double? {
        guard let actual = actualRows, let planned = planRows, actualLoops ?? 1 > 0 else { return nil }
        let a = max(actual, 1)
        let p = max(planned, 1)
        let factor = max(a / p, p / a)
        return factor.isFinite ? factor : nil
    }

    /// The planner's row estimate missed by 10× or more.
    public var isMisestimated: Bool { (estimateFactor ?? 1) >= 10 }
    public var underestimated: Bool { (actualRows ?? 0) > (planRows ?? 0) }

    /// Total rows produced over all loops.
    public var totalActualRows: Double? {
        guard let actualRows else { return nil }
        return actualRows * max(1, actualLoops ?? 1)
    }

    public var flattened: [PlanNode] { [self] + children.flatMap(\.flattened) }
}

public struct PlanDetail: Sendable, Hashable {
    public let name: String
    public let value: String
}

/// A parsed EXPLAIN plan (design: visual EXPLAIN).
public struct ExplainPlan: Sendable {
    public let root: PlanNode
    public let planningTime: Double?
    public let executionTime: Double?
    public let triggers: [PlanDetail]
    public let isAnalyzed: Bool

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Nodes in pre-order.
    public var nodes: [PlanNode] { root.flattened }

    /// The node with the largest exclusive time (ANALYZE only).
    public var slowestNode: PlanNode? {
        nodes.filter { $0.exclusiveTime != nil }.max { ($0.exclusiveTime ?? 0) < ($1.exclusiveTime ?? 0) }
    }

    public var totalTime: Double? { executionTime ?? root.actualTotalTime }

    static let maxNodes = 10_000

    /// Parses the output of `EXPLAIN (FORMAT JSON …)`: a one-element array holding `{"Plan": …}`.
    public static func parse(_ text: String) throws -> ExplainPlan {
        let json: JSONValue
        do {
            json = try JSONValue.parse(text)
        } catch {
            throw ParseError(description: "The plan is not valid JSON (\(error))")
        }
        let top = json.arrayValue?.first ?? json
        guard let planJSON = top["Plan"], planJSON.objectValue != nil else {
            throw ParseError(description: "The output has no \"Plan\" object; run EXPLAIN with FORMAT JSON")
        }
        var nextID = 0
        let root = try node(planJSON, nextID: &nextID, depth: 0)
        let triggers = (top["Triggers"]?.arrayValue ?? []).compactMap { trigger -> PlanDetail? in
            guard let name = trigger["Trigger Name"]?.stringValue else { return nil }
            let time = trigger["Time"]?.doubleValue.map { String(format: "%.3f ms", $0) } ?? ""
            let calls = trigger["Calls"]?.doubleValue.map { "\(Int($0)) calls" } ?? ""
            return PlanDetail(name: name, value: [time, calls].filter { !$0.isEmpty }.joined(separator: ", "))
        }
        return ExplainPlan(root: root, planningTime: top["Planning Time"]?.doubleValue, executionTime: top["Execution Time"]?.doubleValue,
                           triggers: triggers, isAnalyzed: root.actualTotalTime != nil)
    }

    static let knownKeys: Set<String> = [
        "Node Type", "Relation Name", "Schema", "Alias", "Index Name", "Join Type", "Strategy", "Parent Relationship", "Startup Cost",
        "Total Cost", "Plan Rows", "Plan Width", "Actual Startup Time", "Actual Total Time", "Actual Rows", "Actual Loops",
        "Shared Hit Blocks", "Shared Read Blocks", "Temp Read Blocks", "Temp Written Blocks", "Rows Removed by Filter",
        "Workers Planned", "Workers Launched", "Plans", "Parallel Aware", "Async Capable", "Output",
    ]

    static let preferredDetailOrder = [
        "Filter", "Index Cond", "Recheck Cond", "Hash Cond", "Merge Cond", "Join Filter", "Sort Key", "Sort Method", "Sort Space Used",
        "Group Key", "Hash Buckets", "Peak Memory Usage", "Heap Fetches", "Rows Removed by Index Recheck", "Rows Removed by Join Filter",
        "CTE Name", "Function Name", "Subplan Name", "Operation", "Command", "Presorted Key", "Exact Heap Blocks", "Lossy Heap Blocks",
    ]

    static func node(_ json: JSONValue, nextID: inout Int, depth: Int) throws -> PlanNode {
        guard depth < 200 else { throw ParseError(description: "The plan is nested too deeply") }
        guard nextID < maxNodes else { throw ParseError(description: "The plan has too many nodes") }
        let id = nextID
        nextID += 1
        let members = json.objectValue ?? [:]
        func number(_ key: String) -> Double? { members[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil } }
        func text(_ key: String) -> String? { members[key]?.stringValue }
        var children: [PlanNode] = []
        for child in members["Plans"]?.arrayValue ?? [] {
            children.append(try node(child, nextID: &nextID, depth: depth + 1))
        }
        var details: [PlanDetail] = []
        let remaining = members.filter { !knownKeys.contains($0.key) }
        let ordered = preferredDetailOrder.filter { remaining[$0] != nil } + remaining.keys.filter { !preferredDetailOrder.contains($0) }.sorted()
        for key in ordered {
            guard let value = remaining[key] else { continue }
            details.append(PlanDetail(name: key, value: describe(value)))
        }
        let total = number("Actual Total Time")
        let loops = number("Actual Loops") ?? 1
        var exclusive: Double?
        if let total {
            // Children (including InitPlans/SubPlans, which run inside this node) are subtracted.
            let childTime = children.reduce(0.0) { $0 + ($1.actualTotalTime ?? 0) * max(1, $1.actualLoops ?? 1) }
            exclusive = max(0, total * max(1, loops) - childTime)
        }
        let schema = text("Schema")
        let relation = text("Relation Name").map { name in schema.map { "\($0).\(name)" } ?? name }
        return PlanNode(id: id, nodeType: text("Node Type") ?? "Node", relation: relation, alias: text("Alias"), indexName: text("Index Name"),
                        joinType: text("Join Type"), strategy: text("Strategy"), parentRelationship: text("Parent Relationship"),
                        startupCost: number("Startup Cost"), totalCost: number("Total Cost"), planRows: number("Plan Rows"),
                        planWidth: number("Plan Width"), actualStartupTime: number("Actual Startup Time"), actualTotalTime: total,
                        actualRows: number("Actual Rows"), actualLoops: number("Actual Loops"), sharedHitBlocks: number("Shared Hit Blocks"),
                        sharedReadBlocks: number("Shared Read Blocks"), tempReadBlocks: number("Temp Read Blocks"),
                        tempWrittenBlocks: number("Temp Written Blocks"), rowsRemovedByFilter: number("Rows Removed by Filter"),
                        workersPlanned: number("Workers Planned"), workersLaunched: number("Workers Launched"), details: details,
                        children: children, exclusiveTime: exclusive)
    }

    static func describe(_ value: JSONValue) -> String {
        switch value {
        case let .string(text): text
        case let .array(items): items.map(describe).joined(separator: ", ")
        case let .bool(flag): flag ? "true" : "false"
        case .null: "null"
        default: value.serialized()
        }
    }

    /// Compact text rendering for MCP results and copying (indented tree with times and estimate misses).
    public func summary(maxLines: Int = 400) -> String {
        var lines: [String] = []
        func visit(_ node: PlanNode, depth: Int) {
            guard lines.count < maxLines else { return }
            var line = String(repeating: "  ", count: depth) + "-> " + node.title
            if let subtitle = node.subtitle { line += " " + subtitle }
            if let cost = node.totalCost { line += String(format: " (cost=%.2f rows=%.0f)", cost, node.planRows ?? 0) }
            if let time = node.actualTotalTime {
                line += String(format: " (actual %.3f ms × %.0f loops, rows=%.0f)", time, node.actualLoops ?? 1, node.actualRows ?? 0)
            }
            if let exclusive = node.exclusiveTime { line += String(format: " [self %.3f ms]", exclusive) }
            if node.isMisestimated, let factor = node.estimateFactor {
                line += String(format: " [rows %@estimated %.0f×]", node.underestimated ? "under" : "over", factor)
            }
            lines.append(line)
            for detail in node.details.prefix(4) { lines.append(String(repeating: "  ", count: depth + 2) + "\(detail.name): \(detail.value)") }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        visit(root, depth: 0)
        if let planningTime { lines.append(String(format: "Planning time: %.3f ms", planningTime)) }
        if let executionTime { lines.append(String(format: "Execution time: %.3f ms", executionTime)) }
        return lines.joined(separator: "\n")
    }

    /// `EXPLAIN (FORMAT JSON[, ANALYZE, BUFFERS]) …` for a statement.
    public static func statement(for sql: String, analyze: Bool, buffers: Bool) -> String {
        var body = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while body.hasSuffix(";") { body.removeLast() }
        var options = ["FORMAT JSON"]
        if analyze { options.append("ANALYZE") }
        if buffers { options.append("BUFFERS") }
        return "EXPLAIN (\(options.joined(separator: ", "))) \(body)"
    }
}
