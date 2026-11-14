import CcinnPsqlKit
import SwiftUI

/// Visual EXPLAIN: an indented node tree with self-time (or cost) bars, row-estimate misses, buffers and a detail
/// inspector for the selected node.
struct PlanView: View {
    let plan: ExplainPlan
    @State private var selectedID: Int?
    @State private var showText = false

    private struct Row: Identifiable {
        let node: PlanNode
        let depth: Int
        var id: Int { node.id }
    }

    private var rows: [Row] {
        var result: [Row] = []
        func visit(_ node: PlanNode, _ depth: Int) {
            result.append(Row(node: node, depth: depth))
            for child in node.children { visit(child, depth + 1) }
        }
        visit(plan.root, 0)
        return result
    }

    /// The metric the bars show: exclusive time with ANALYZE, otherwise total cost.
    private func metric(_ node: PlanNode) -> Double {
        plan.isAnalyzed ? (node.exclusiveTime ?? 0) : (node.totalCost ?? 0)
    }

    var body: some View {
        let rows = self.rows
        let maximum = max(rows.map { metric($0.node) }.max() ?? 1, 0.000_001)
        let slowest = plan.slowestNode?.id
        HSplitView {
            VStack(spacing: 0) {
                summary
                Divider()
                if showText {
                    ScrollView([.vertical, .horizontal]) {
                        Text(plan.summary(maxLines: 5_000))
                            .font(Theme.monospacedSmall)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(rows) { row in
                                PlanNodeRow(node: row.node, depth: row.depth, share: metric(row.node) / maximum, analyzed: plan.isAnalyzed,
                                            isSlowest: row.node.id == slowest, isSelected: selectedID == row.node.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedID = row.node.id }
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .frame(minWidth: 420)
            PlanInspector(node: rows.first { $0.node.id == (selectedID ?? slowest ?? plan.root.id) }?.node ?? plan.root, plan: plan)
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            if let execution = plan.executionTime {
                Badge(text: "Execution \(Format.duration(milliseconds: execution))", color: Theme.accent, systemImage: "stopwatch")
            }
            if let planning = plan.planningTime {
                Badge(text: "Planning \(Format.duration(milliseconds: planning))", color: .secondary)
            }
            if let cost = plan.root.totalCost {
                Badge(text: "Cost \(String(format: "%.1f", cost))", color: .secondary)
            }
            let misses = plan.nodes.filter(\.isMisestimated).count
            if misses > 0 {
                Badge(text: "\(misses) row estimate miss\(misses == 1 ? "" : "es")", color: .orange, systemImage: "exclamationmark.triangle")
                    .help("Nodes where actual rows differ from the planner's estimate by 10× or more; consider ANALYZE or extended statistics.")
            }
            if !plan.isAnalyzed {
                Text("Estimated plan — use Explain Analyze for actual times").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(isOn: $showText) { Image(systemName: "text.alignleft") }
                .toggleStyle(.button)
                .help("Show as text")
            Button {
                Pasteboard.copy(plan.summary(maxLines: 5_000))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy plan as text")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct PlanNodeRow: View {
    let node: PlanNode
    let depth: Int
    let share: Double
    let analyzed: Bool
    let isSlowest: Bool
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Color.clear.frame(width: CGFloat(min(depth, 30)) * 14)
                if depth > 0 { Image(systemName: "arrow.turn.down.right").font(.caption2).foregroundStyle(.tertiary) }
                Image(systemName: icon).foregroundStyle(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(node.title).font(.callout.weight(.semibold))
                        if let subtitle = node.subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                        if isSlowest { Badge(text: "slowest", color: .red, systemImage: "flame") }
                        if node.isMisestimated, let factor = node.estimateFactor {
                            Badge(text: "\(node.underestimated ? "↑" : "↓")\(Int(min(factor, 999_999).rounded()))×", color: .orange)
                                .help("Planner estimated \(Int(node.planRows ?? 0)) rows per loop; actual \(Int(node.actualRows ?? 0))")
                        }
                    }
                    if let detail = node.details.first {
                        Text("\(detail.name): \(detail.value)").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(primaryMetric).font(.caption.monospacedDigit())
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(barColor.gradient).frame(width: max(2, proxy.size.width * min(1, max(0, share))))
                    }
                }
                .frame(width: 120, height: 6)
                Text(rowsText).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private var primaryMetric: String {
        if analyzed, let exclusive = node.exclusiveTime { return Format.duration(milliseconds: exclusive) + " self" }
        if let cost = node.totalCost { return String(format: "cost %.1f", cost) }
        return ""
    }

    private var rowsText: String {
        if analyzed, let actual = node.actualRows {
            let loops = node.actualLoops ?? 1
            return "\(Int(actual).formatted()) rows" + (loops > 1 ? " × \(Int(loops).formatted())" : "") + " · est \(Int(node.planRows ?? 0).formatted())"
        }
        return "est \(Int(node.planRows ?? 0).formatted()) rows"
    }

    private var barColor: Color { isSlowest ? .red : (share > 0.5 ? .orange : Theme.accent) }

    private var icon: String {
        let type = node.nodeType
        if type.contains("Seq Scan") { return "list.bullet" }
        if type.contains("Index") { return "magnifyingglass" }
        if type.contains("Join") || type == "Nested Loop" { return "arrow.triangle.merge" }
        if type.contains("Sort") { return "arrow.up.arrow.down" }
        if type.contains("Aggregate") || type.contains("Group") { return "sum" }
        if type.contains("Hash") { return "number" }
        if type.contains("Gather") { return "square.stack.3d.down.forward" }
        if type.contains("Limit") { return "line.3.horizontal.decrease" }
        if type.contains("Modify") { return "pencil" }
        return "circle.dotted"
    }

    private var color: Color {
        node.nodeType.contains("Seq Scan") && (node.rowsRemovedByFilter ?? 0) > (node.actualRows ?? 0) * 10 ? .orange : Theme.accent
    }
}

private struct PlanInspector: View {
    let node: PlanNode
    let plan: ExplainPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title).font(.headline)
                if let subtitle = node.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                KeyValueList(items: metrics)
                if !node.details.isEmpty {
                    Divider()
                    KeyValueList(items: node.details.map { ($0.name, $0.value) }, monospacedValues: true)
                }
                if node.id == plan.root.id, !plan.triggers.isEmpty {
                    Divider()
                    Text("Triggers").font(.subheadline.weight(.semibold))
                    KeyValueList(items: plan.triggers.map { ($0.name, $0.value) })
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var metrics: [(String, String)] {
        var items: [(String, String)] = []
        if let startup = node.startupCost, let total = node.totalCost { items.append(("Cost", String(format: "%.2f … %.2f", startup, total))) }
        if let rows = node.planRows { items.append(("Planned rows", Int(rows).formatted())) }
        if let width = node.planWidth { items.append(("Row width", "\(Int(width)) bytes")) }
        if let time = node.actualTotalTime { items.append(("Actual time", String(format: "%.3f ms per loop", time))) }
        if let exclusive = node.exclusiveTime { items.append(("Self time", Format.duration(milliseconds: exclusive))) }
        if let rows = node.actualRows { items.append(("Actual rows", Int(rows).formatted() + " per loop")) }
        if let loops = node.actualLoops { items.append(("Loops", Int(loops).formatted())) }
        if let factor = node.estimateFactor, factor > 1.5 {
            items.append(("Estimate", "\(node.underestimated ? "under" : "over")estimated \(String(format: "%.1f", factor))×"))
        }
        if let removed = node.rowsRemovedByFilter { items.append(("Removed by filter", Int(removed).formatted())) }
        if let hit = node.sharedHitBlocks { items.append(("Shared hit", "\(Int(hit).formatted()) blocks")) }
        if let read = node.sharedReadBlocks { items.append(("Shared read", "\(Int(read).formatted()) blocks")) }
        if let temp = node.tempWrittenBlocks, temp > 0 { items.append(("Temp written", "\(Int(temp).formatted()) blocks")) }
        if let planned = node.workersPlanned { items.append(("Workers", "\(Int(node.workersLaunched ?? 0)) of \(Int(planned)) launched")) }
        return items
    }
}
