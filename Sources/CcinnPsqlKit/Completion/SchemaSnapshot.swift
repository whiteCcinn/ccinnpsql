import Foundation
import PostgresKit

/// Case-insensitive `schema.table` key.
public struct TableKey: Hashable, Sendable, CustomStringConvertible {
    public let schema: String
    public let table: String

    public init(schema: String, table: String) {
        self.schema = schema.lowercased()
        self.table = table.lowercased()
    }

    public var description: String { "\(schema).\(table)" }
}

/// What completion knows about the database. Built by the app from lazily loaded metadata; immutable, so
/// completion runs off the main actor without locks.
public struct SchemaSnapshot: Sendable {
    public struct ObjectEntry: Sendable, Hashable {
        public let name: String
        public let kind: RelationKind

        public init(name: String, kind: RelationKind) {
            self.name = name
            self.kind = kind
        }
    }

    public struct ColumnEntry: Sendable, Hashable {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// Schemas searched for unqualified names (`search_path`, usually `public`).
    public var searchPath: [String]
    public var schemas: [String]
    /// Relations per schema (keys lower-cased).
    public var objectsBySchema: [String: [ObjectEntry]]
    public var columnsByTable: [TableKey: [ColumnEntry]]
    /// User-defined functions per schema (keys lower-cased).
    public var functionsBySchema: [String: [RoutineSummary]]

    public init(searchPath: [String] = ["public"], schemas: [String] = [], objectsBySchema: [String: [ObjectEntry]] = [:],
                columnsByTable: [TableKey: [ColumnEntry]] = [:], functionsBySchema: [String: [RoutineSummary]] = [:]) {
        self.searchPath = searchPath
        self.schemas = schemas
        self.objectsBySchema = Dictionary(objectsBySchema.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.columnsByTable = columnsByTable
        self.functionsBySchema = Dictionary(functionsBySchema.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
    }

    public var currentSchema: String? { searchPath.first }

    public func objects(in schema: String) -> [ObjectEntry]? {
        objectsBySchema[schema.lowercased()]
    }

    public func columns(schema: String, table: String) -> [ColumnEntry]? {
        columnsByTable[TableKey(schema: schema, table: table)]
    }

    public func isSchema(_ name: String) -> Bool {
        schemas.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func object(named name: String, in schema: String) -> ObjectEntry? {
        objects(in: schema)?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The schema an unqualified relation name resolves to via the search path.
    public func resolveSchema(of table: String) -> String? {
        searchPath.first { object(named: table, in: $0) != nil }
    }
}
