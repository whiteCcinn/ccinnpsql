import Foundation
import PostgresKit

/// Relationships from every machine source for one refresh: declared foreign keys, joins inside view and materialized
/// view definitions, joins in the editor history, and names. The refresher merges them (one record per pair of ends)
/// and keeps what the user and AI added.
public enum KnowledgeInference {
    public static let machineRelationships: KnowledgeToolSettings.Inference = { (input: KnowledgeInferenceInput) -> [Relationship] in
        let knowledge = input.knowledge
        let live = knowledge.tables.filter { $0.state != .dropped }
        var relationships = declared(input.schema, knowledge: knowledge, now: input.now)
        relationships += NamingHeuristics.relationships(tables: live, now: input.now)
        relationships += HistoryJoinMiner.relationships(entries: input.history, knowledge: knowledge, now: input.now)
        for table in input.schema.tables {
            guard let definition = table.definition, table.kind != .table else { continue }
            relationships += HistoryJoinMiner.definitionRelationships(definition: definition, viewName: table.name, knowledge: knowledge, now: input.now)
        }
        return relationships
    }

    /// Declared foreign keys as relationships with `declared` evidence: 100 when PostgreSQL guarantees every row (enforced
    /// and validated), 95 for `NOT VALID` and `NOT ENFORCED` ones. A foreign key on the referencing table's own primary or
    /// unique key is one-to-one.
    static func declared(_ schema: ExtractedSchema, knowledge: DatabaseKnowledge, now: Date) -> [Relationship] {
        var keysByTable: [String: TableFacts.Keys] = [:]
        for table in schema.tables { keysByTable[table.name] = table.keys }
        return schema.foreignKeys.map { (key: ExtractedForeignKey) -> Relationship in
            let otherSchema: String? = key.referencedSchema == schema.database ? nil : key.referencedSchema
            let from = Relationship.End(table: key.table, columns: key.columns)
            let to = Relationship.End(database: otherSchema, table: key.referencedTable, columns: key.referencedColumns)
            let isOneToOne = keysByTable[key.table]?.identifiesRow(key.columns) ?? false
            let evidence = Evidence(source: .declared, score: key.isGuaranteed ? 100 : 95, at: now)
            return Relationship(from: from, to: to, kind: isOneToOne ? .oneToOne : .manyToOne, evidence: [evidence])
        }
    }
}
