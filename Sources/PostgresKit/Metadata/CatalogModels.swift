import Foundation

/// A database of the cluster.
public struct DatabaseSummary: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let owner: String?
    public let encoding: String?
    public let collation: String?
    public let sizeBytes: Int64?
    public let allowsConnections: Bool
    public let isTemplate: Bool
    public let connectionLimit: Int?
    /// `age(datfrozenxid)`: distance to transaction-ID wraparound protection.
    public let transactionIDAge: Int64?
    public let comment: String?

    public init(name: String, owner: String? = nil, encoding: String? = nil, collation: String? = nil, sizeBytes: Int64? = nil,
                allowsConnections: Bool = true, isTemplate: Bool = false, connectionLimit: Int? = nil, transactionIDAge: Int64? = nil,
                comment: String? = nil) {
        self.name = name
        self.owner = owner
        self.encoding = encoding
        self.collation = collation
        self.sizeBytes = sizeBytes
        self.allowsConnections = allowsConnections
        self.isTemplate = isTemplate
        self.connectionLimit = connectionLimit
        self.transactionIDAge = transactionIDAge
        self.comment = comment
    }
}

public struct SchemaSummary: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let owner: String?
    public let comment: String?

    public init(name: String, owner: String? = nil, comment: String? = nil) {
        self.name = name
        self.owner = owner
        self.comment = comment
    }

    /// pg_catalog, information_schema, pg_toast/pg_temp_*, and internal schemas of common extensions.
    public var isSystem: Bool { Self.isSystemSchema(name) }

    public static func isSystemSchema(_ name: String) -> Bool {
        name == "information_schema" || name.hasPrefix("pg_") || name.hasPrefix("_timescaledb") || name == "timescaledb_information"
            || name == "timescaledb_experimental" || name == "citus" || name == "citus_internal" || name == "columnar"
            || name == "columnar_internal"
    }
}

/// `pg_class.relkind` values the browser shows.
public enum RelationKind: String, Sendable, Hashable, CaseIterable {
    case table = "r"
    case partitionedTable = "p"
    case view = "v"
    case materializedView = "m"
    case foreignTable = "f"
    case sequence = "S"

    public var displayName: String {
        switch self {
        case .table: "Table"
        case .partitionedTable: "Partitioned table"
        case .view: "View"
        case .materializedView: "Materialized view"
        case .foreignTable: "Foreign table"
        case .sequence: "Sequence"
        }
    }

    public var isTableLike: Bool { self == .table || self == .partitionedTable || self == .foreignTable }
    public var hasStorage: Bool { self == .table || self == .materializedView }
}

/// How Citus places a table.
public enum CitusPlacement: String, Sendable, Hashable {
    case distributed
    case reference
    case local
}

/// A table, view, materialized view, foreign table or sequence.
public struct RelationSummary: Sendable, Hashable, Identifiable {
    public var id: UInt32 { oid }
    public let oid: UInt32
    public let schema: String
    public let name: String
    public let kind: RelationKind
    /// `relpersistence`: `p` permanent, `u` unlogged, `t` temporary.
    public let persistence: String
    public let isPartition: Bool
    /// `FOR VALUES …` of a partition.
    public let partitionBound: String?
    /// OID of the parent (partitioned table or inheritance parent).
    public let parentOID: UInt32?
    /// Has inheritance children or partitions.
    public let hasChildren: Bool
    /// `reltuples`; `nil` when never analyzed (`-1` on PostgreSQL 14+).
    public let estimatedRows: Int64?
    /// `pg_total_relation_size` (sum of partitions for partitioned tables).
    public let totalBytes: Int64?
    public let owner: String?
    public let comment: String?
    public var isHypertable: Bool
    public var citusPlacement: CitusPlacement?
    /// Distribution column of a Citus distributed table.
    public var distributionColumn: String?

    public init(oid: UInt32, schema: String, name: String, kind: RelationKind, persistence: String = "p", isPartition: Bool = false,
                partitionBound: String? = nil, parentOID: UInt32? = nil, hasChildren: Bool = false, estimatedRows: Int64? = nil,
                totalBytes: Int64? = nil, owner: String? = nil, comment: String? = nil, isHypertable: Bool = false,
                citusPlacement: CitusPlacement? = nil, distributionColumn: String? = nil) {
        self.oid = oid
        self.schema = schema
        self.name = name
        self.kind = kind
        self.persistence = persistence
        self.isPartition = isPartition
        self.partitionBound = partitionBound
        self.parentOID = parentOID
        self.hasChildren = hasChildren
        self.estimatedRows = estimatedRows
        self.totalBytes = totalBytes
        self.owner = owner
        self.comment = comment
        self.isHypertable = isHypertable
        self.citusPlacement = citusPlacement
        self.distributionColumn = distributionColumn
    }

    public var qualifiedName: String { SQLText.qualified(schema, name) }
    public var isUnlogged: Bool { persistence == "u" }
    public var isTemporary: Bool { persistence == "t" }

    func with(totalBytes newTotal: Int64?) -> RelationSummary {
        var copy = RelationSummary(oid: oid, schema: schema, name: name, kind: kind, persistence: persistence, isPartition: isPartition,
                                   partitionBound: partitionBound, parentOID: parentOID, hasChildren: hasChildren,
                                   estimatedRows: estimatedRows, totalBytes: newTotal, owner: owner, comment: comment)
        copy.isHypertable = isHypertable
        copy.citusPlacement = citusPlacement
        copy.distributionColumn = distributionColumn
        return copy
    }
}

/// A relation with its partitions / inheritance children nested (sidebar tree).
public struct RelationNode: Sendable, Hashable, Identifiable {
    public var id: UInt32 { relation.oid }
    public let relation: RelationSummary
    public let children: [RelationNode]

    public init(relation: RelationSummary, children: [RelationNode] = []) {
        self.relation = relation
        self.children = children
    }

    /// Nests partitions and inheritance children under their parent (cycle-safe, depth-bounded). Children whose
    /// parent is not in `relations` (another schema) stay at the top level.
    public static func tree(_ relations: [RelationSummary], maxDepth: Int = 32) -> [RelationNode] {
        let byOID = Dictionary(relations.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [UInt32: [RelationSummary]] = [:]
        var roots: [RelationSummary] = []
        for relation in relations {
            if let parent = relation.parentOID, parent != relation.oid, byOID[parent] != nil {
                children[parent, default: []].append(relation)
            } else {
                roots.append(relation)
            }
        }
        var visited: Set<UInt32> = []
        func build(_ relation: RelationSummary, depth: Int) -> RelationNode {
            visited.insert(relation.oid)
            guard depth < maxDepth else { return RelationNode(relation: relation) }
            let nested = (children[relation.oid] ?? [])
                .filter { !visited.contains($0.oid) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { build($0, depth: depth + 1) }
            return RelationNode(relation: relation, children: nested)
        }
        var result = roots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { build($0, depth: 0) }
        // Relations only reachable through a cycle become roots so nothing disappears.
        for relation in relations where !visited.contains(relation.oid) {
            result.append(build(relation, depth: 0))
        }
        return result
    }

    /// Sum of storage of this node and every descendant (partitioned tables have no storage of their own).
    public var totalBytesIncludingChildren: Int64? {
        let own = relation.totalBytes ?? 0
        let nested = children.reduce(Int64(0)) { $0 &+ ($1.totalBytesIncludingChildren ?? 0) }
        let sum = own &+ nested
        return relation.totalBytes == nil && children.isEmpty ? nil : sum
    }
}

public enum RoutineKind: String, Sendable, Hashable {
    case function = "f"
    case procedure = "p"
    case aggregate = "a"
    case window = "w"

    public var displayName: String {
        switch self {
        case .function: "Function"
        case .procedure: "Procedure"
        case .aggregate: "Aggregate"
        case .window: "Window function"
        }
    }
}

public struct RoutineSummary: Sendable, Hashable, Identifiable {
    public var id: UInt32 { oid }
    public let oid: UInt32
    public let schema: String
    public let name: String
    public let kind: RoutineKind
    /// `pg_get_function_identity_arguments`.
    public let arguments: String
    public let result: String?
    public let language: String
    /// `i` immutable, `s` stable, `v` volatile.
    public let volatility: String
    public let isSecurityDefiner: Bool
    public let comment: String?

    public init(oid: UInt32, schema: String, name: String, kind: RoutineKind, arguments: String, result: String?, language: String,
                volatility: String, isSecurityDefiner: Bool = false, comment: String? = nil) {
        self.oid = oid
        self.schema = schema
        self.name = name
        self.kind = kind
        self.arguments = arguments
        self.result = result
        self.language = language
        self.volatility = volatility
        self.isSecurityDefiner = isSecurityDefiner
        self.comment = comment
    }

    public var signature: String { "\(name)(\(arguments))" }

    public var volatilityName: String {
        switch volatility {
        case "i": "IMMUTABLE"
        case "s": "STABLE"
        default: "VOLATILE"
        }
    }
}

public enum TypeKind: String, Sendable, Hashable {
    case base = "b"
    case composite = "c"
    case domain = "d"
    case enumeration = "e"
    case range = "r"
    case multirange = "m"

    public var displayName: String {
        switch self {
        case .base: "Base type"
        case .composite: "Composite type"
        case .domain: "Domain"
        case .enumeration: "Enum"
        case .range: "Range"
        case .multirange: "Multirange"
        }
    }
}

public struct TypeSummary: Sendable, Hashable, Identifiable {
    public var id: UInt32 { oid }
    public let oid: UInt32
    public let schema: String
    public let name: String
    public let kind: TypeKind
    public let comment: String?

    public init(oid: UInt32, schema: String, name: String, kind: TypeKind, comment: String? = nil) {
        self.oid = oid
        self.schema = schema
        self.name = name
        self.kind = kind
        self.comment = comment
    }
}

public struct ExtensionSummary: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public let name: String
    public let installedVersion: String?
    public let defaultVersion: String?
    public let schema: String?
    public let comment: String?

    public init(name: String, installedVersion: String?, defaultVersion: String?, schema: String?, comment: String?) {
        self.name = name
        self.installedVersion = installedVersion
        self.defaultVersion = defaultVersion
        self.schema = schema
        self.comment = comment
    }

    public var isInstalled: Bool { installedVersion != nil }
    /// An installed extension whose default version is newer (`ALTER EXTENSION … UPDATE`).
    public var hasUpdate: Bool {
        guard let installedVersion, let defaultVersion else { return false }
        return installedVersion != defaultVersion
    }
}

/// Everything the sidebar shows for one schema.
public struct SchemaContents: Sendable {
    public let schema: String
    public let relations: [RelationSummary]
    public let routines: [RoutineSummary]
    public let types: [TypeSummary]

    public init(schema: String, relations: [RelationSummary], routines: [RoutineSummary], types: [TypeSummary]) {
        self.schema = schema
        self.relations = relations
        self.routines = routines
        self.types = types
    }

    public var tree: [RelationNode] { RelationNode.tree(relations.filter { $0.kind != .sequence }) }
    public func relations(of kind: RelationKind) -> [RelationSummary] { relations.filter { $0.kind == kind } }
}
