import Foundation

/// Built-in type OIDs (stable across PostgreSQL versions) and their classification.
public struct PostgresType: Sendable, Hashable {
    public let oid: UInt32
    public let name: String

    public init(oid: UInt32, name: String) {
        self.oid = oid
        self.name = name
    }

    /// Broad category used for alignment, sorting, charts and export.
    public enum Kind: Sendable, Equatable {
        case boolean
        case integer
        case float
        case decimal
        case date
        case dateTime
        case time
        case interval
        case text
        case json
        case binary
        case uuid
        case network
        case array
        case other
    }

    public static let bool = PostgresType(oid: 16, name: "bool")
    public static let bytea = PostgresType(oid: 17, name: "bytea")
    public static let char = PostgresType(oid: 18, name: "char")
    public static let name = PostgresType(oid: 19, name: "name")
    public static let int8 = PostgresType(oid: 20, name: "int8")
    public static let int2 = PostgresType(oid: 21, name: "int2")
    public static let int4 = PostgresType(oid: 23, name: "int4")
    public static let regproc = PostgresType(oid: 24, name: "regproc")
    public static let text = PostgresType(oid: 25, name: "text")
    public static let oid = PostgresType(oid: 26, name: "oid")
    public static let xid = PostgresType(oid: 28, name: "xid")
    public static let cid = PostgresType(oid: 29, name: "cid")
    public static let json = PostgresType(oid: 114, name: "json")
    public static let xml = PostgresType(oid: 142, name: "xml")
    public static let pgNodeTree = PostgresType(oid: 194, name: "pg_node_tree")
    public static let point = PostgresType(oid: 600, name: "point")
    public static let cidr = PostgresType(oid: 650, name: "cidr")
    public static let float4 = PostgresType(oid: 700, name: "float4")
    public static let float8 = PostgresType(oid: 701, name: "float8")
    public static let unknown = PostgresType(oid: 705, name: "unknown")
    public static let money = PostgresType(oid: 790, name: "money")
    public static let macaddr = PostgresType(oid: 829, name: "macaddr")
    public static let inet = PostgresType(oid: 869, name: "inet")
    public static let aclitem = PostgresType(oid: 1033, name: "aclitem")
    public static let bpchar = PostgresType(oid: 1042, name: "bpchar")
    public static let varchar = PostgresType(oid: 1043, name: "varchar")
    public static let date = PostgresType(oid: 1082, name: "date")
    public static let time = PostgresType(oid: 1083, name: "time")
    public static let timestamp = PostgresType(oid: 1114, name: "timestamp")
    public static let timestamptz = PostgresType(oid: 1184, name: "timestamptz")
    public static let interval = PostgresType(oid: 1186, name: "interval")
    public static let timetz = PostgresType(oid: 1266, name: "timetz")
    public static let bit = PostgresType(oid: 1560, name: "bit")
    public static let varbit = PostgresType(oid: 1562, name: "varbit")
    public static let numeric = PostgresType(oid: 1700, name: "numeric")
    public static let refcursor = PostgresType(oid: 1790, name: "refcursor")
    public static let regclass = PostgresType(oid: 2205, name: "regclass")
    public static let regtype = PostgresType(oid: 2206, name: "regtype")
    public static let record = PostgresType(oid: 2249, name: "record")
    public static let void = PostgresType(oid: 2278, name: "void")
    public static let uuid = PostgresType(oid: 2950, name: "uuid")
    public static let pgLsn = PostgresType(oid: 3220, name: "pg_lsn")
    public static let tsvector = PostgresType(oid: 3614, name: "tsvector")
    public static let jsonb = PostgresType(oid: 3802, name: "jsonb")
    public static let int4range = PostgresType(oid: 3904, name: "int4range")
    public static let tstzrange = PostgresType(oid: 3910, name: "tstzrange")
    public static let jsonpath = PostgresType(oid: 4072, name: "jsonpath")
    public static let regnamespace = PostgresType(oid: 4089, name: "regnamespace")
    public static let regrole = PostgresType(oid: 4096, name: "regrole")
    public static let xid8 = PostgresType(oid: 5069, name: "xid8")

    static let scalars: [PostgresType] = [
        .bool, .bytea, .char, .name, .int8, .int2, .int4, .regproc, .text, .oid, .xid, .cid, .json, .xml, .pgNodeTree, .point, .cidr,
        .float4, .float8, .unknown, .money, .macaddr, .inet, .aclitem, .bpchar, .varchar, .date, .time, .timestamp, .timestamptz,
        .interval, .timetz, .bit, .varbit, .numeric, .refcursor, .regclass, .regtype, .record, .void, .uuid, .pgLsn, .tsvector,
        .jsonb, .int4range, .tstzrange, .jsonpath, .regnamespace, .regrole, .xid8,
        PostgresType(oid: 2275, name: "cstring"), PostgresType(oid: 3926, name: "int8range"), PostgresType(oid: 3906, name: "numrange"),
        PostgresType(oid: 3908, name: "tsrange"), PostgresType(oid: 3912, name: "daterange"), PostgresType(oid: 3615, name: "tsquery"),
        PostgresType(oid: 601, name: "lseg"), PostgresType(oid: 602, name: "path"), PostgresType(oid: 603, name: "box"),
        PostgresType(oid: 604, name: "polygon"), PostgresType(oid: 628, name: "line"), PostgresType(oid: 718, name: "circle"),
        PostgresType(oid: 774, name: "macaddr8"), PostgresType(oid: 2202, name: "regprocedure"), PostgresType(oid: 2203, name: "regoper"),
        PostgresType(oid: 2204, name: "regoperator"), PostgresType(oid: 3734, name: "regconfig"), PostgresType(oid: 3769, name: "regdictionary"),
        PostgresType(oid: 4600, name: "pg_brin_bloom_summary"), PostgresType(oid: 3361, name: "pg_ndistinct"),
        PostgresType(oid: 3402, name: "pg_dependencies"), PostgresType(oid: 5017, name: "pg_mcv_list"), PostgresType(oid: 32, name: "pg_ddl_command"),
    ]

    /// Array type OID → element type for the built-in arrays.
    static let arrays: [UInt32: UInt32] = [
        1000: 16, 1001: 17, 1002: 18, 1003: 19, 1016: 20, 1005: 21, 1007: 23, 1008: 24, 1009: 25, 1028: 26, 1011: 28, 1012: 29,
        199: 114, 143: 142, 1017: 600, 651: 650, 1021: 700, 1022: 701, 791: 790, 1040: 829, 1041: 869, 1034: 1033, 1014: 1042,
        1015: 1043, 1182: 1082, 1183: 1083, 1115: 1114, 1185: 1184, 1187: 1186, 1270: 1266, 1561: 1560, 1563: 1562, 1231: 1700,
        2210: 2205, 2211: 2206, 2287: 2249, 2951: 2950, 3221: 3220, 3643: 3614, 3807: 3802, 3905: 3904, 3911: 3910, 4073: 4072,
        4090: 4089, 4097: 4096, 271: 5069, 1263: 2275,
    ]

    static let byOID: [UInt32: PostgresType] = Dictionary(scalars.map { ($0.oid, $0) }, uniquingKeysWith: { first, _ in first })

    /// Name of a built-in type (`_int4` for arrays, as `pg_type.typname`); `nil` for user types.
    public static func name(of oid: UInt32) -> String? {
        if let type = byOID[oid] { return type.name }
        if let element = arrays[oid], let elementName = byOID[element]?.name { return "_" + elementName }
        return nil
    }

    public static func isArray(_ oid: UInt32) -> Bool { arrays[oid] != nil }

    public static func kind(of oid: UInt32) -> Kind {
        if arrays[oid] != nil { return .array }
        switch oid {
        case 16: return .boolean
        case 20, 21, 23, 26, 28, 29, 5069: return .integer
        case 700, 701: return .float
        case 1700, 790: return .decimal
        case 1082: return .date
        case 1114, 1184: return .dateTime
        case 1083, 1266: return .time
        case 1186: return .interval
        case 114, 3802, 4072: return .json
        case 17: return .binary
        case 2950: return .uuid
        case 650, 869, 829, 774: return .network
        default: return .text
        }
    }

    /// Types whose binary representation `BinaryValue` turns into PostgreSQL's canonical text.
    public static let binaryDecodable: [PostgresType] = [
        .bool, .bytea, .char, .name, .int8, .int2, .int4, .text, .oid, .xid, .cid, .json, .cidr, .float4, .float8, .unknown, .macaddr,
        .inet, .bpchar, .varchar, .date, .time, .timestamp, .timestamptz, .interval, .timetz, .numeric, .uuid, .jsonb, .xid8,
    ]

    static let binaryDecodableOIDs: Set<UInt32> = Set(binaryDecodable.map(\.oid))

    public static func supportsBinary(_ oid: UInt32) -> Bool { binaryDecodableOIDs.contains(oid) }
}
