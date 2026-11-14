import Foundation

/// Transaction state reported by ReadyForQuery.
public enum TransactionStatus: Sendable, Equatable {
    case idle
    case inTransaction
    case failedTransaction

    init(byte: UInt8) throws {
        switch byte {
        case 0x49: self = .idle // I
        case 0x54: self = .inTransaction // T
        case 0x45: self = .failedTransaction // E
        default: throw PostgresWireError.invalid("transaction status \(byte)")
        }
    }
}

/// Authentication request codes (message `R`).
public enum AuthenticationRequest: Sendable, Equatable {
    case ok
    case cleartextPassword
    case md5Password(salt: [UInt8])
    case sasl(mechanisms: [String])
    case saslContinue([UInt8])
    case saslFinal([UInt8])
    /// Kerberos, GSS, SSPI and anything unknown.
    case unsupported(Int32)
}

/// One column of a RowDescription.
public struct FieldDescription: Sendable, Equatable {
    public var name: String
    public var tableOID: UInt32
    public var columnNumber: Int16
    public var typeOID: UInt32
    public var typeSize: Int16
    public var typeModifier: Int32
    public var format: FormatCode

    public init(name: String, tableOID: UInt32 = 0, columnNumber: Int16 = 0, typeOID: UInt32, typeSize: Int16 = -1,
                typeModifier: Int32 = -1, format: FormatCode = .text) {
        self.name = name
        self.tableOID = tableOID
        self.columnNumber = columnNumber
        self.typeOID = typeOID
        self.typeSize = typeSize
        self.typeModifier = typeModifier
        self.format = format
    }
}

/// Fields of an ErrorResponse or NoticeResponse.
public struct ServerMessageFields: Sendable, Equatable {
    /// Raw fields by their one-byte code.
    public var fields: [UInt8: String]

    public init(fields: [UInt8: String]) {
        self.fields = fields
    }

    subscript(_ code: Character) -> String? {
        guard let ascii = code.asciiValue else { return nil }
        return fields[ascii]
    }

    /// Localized severity (`S`), falling back to the non-localized one (`V`).
    public var severity: String { self["S"] ?? self["V"] ?? "ERROR" }
    /// Non-localized severity (`V`, PostgreSQL 9.6+).
    public var nonLocalizedSeverity: String? { self["V"] }
    public var sqlState: String? { self["C"] }
    public var message: String { self["M"] ?? "" }
    public var detail: String? { self["D"] }
    public var hint: String? { self["H"] }
    /// 1-based character position of the error in the statement (`P`).
    public var position: Int? { Self.positive(self["P"]) }
    /// Position inside `internalQuery` (`p`).
    public var internalPosition: Int? { Self.positive(self["p"]) }
    public var internalQuery: String? { self["q"] }
    public var whereContext: String? { self["W"] }
    public var schemaName: String? { self["s"] }
    public var tableName: String? { self["t"] }
    public var columnName: String? { self["c"] }
    public var dataTypeName: String? { self["d"] }
    public var constraintName: String? { self["n"] }
    public var file: String? { self["F"] }
    public var line: String? { self["L"] }
    public var routine: String? { self["R"] }

    static func positive(_ text: String?) -> Int? {
        guard let text, text.utf8.count <= 10, let value = Int(text), value > 0 else { return nil }
        return value
    }

    static func parse(_ payload: ArraySlice<UInt8>) throws -> ServerMessageFields {
        var reader = ByteReader(payload)
        var fields: [UInt8: String] = [:]
        while true {
            let code = try reader.readUInt8()
            if code == 0 { break }
            fields[code] = try reader.readCString()
        }
        return ServerMessageFields(fields: fields)
    }
}

/// An asynchronous NOTIFY delivered to a listening session.
public struct NotificationMessage: Sendable, Equatable {
    public var processID: Int32
    public var channel: String
    public var payload: String

    public init(processID: Int32, channel: String, payload: String) {
        self.processID = processID
        self.channel = channel
        self.payload = payload
    }
}

/// Format information of a CopyIn/CopyOut/CopyBoth response.
public struct CopyFormat: Sendable, Equatable {
    public var isBinary: Bool
    public var columnFormats: [FormatCode]
}

/// A parsed backend message. `dataRow` and `copyData` reference the decoder's buffer: consume them
/// before appending more bytes.
public enum BackendMessage: Sendable {
    case authentication(AuthenticationRequest)
    case backendKeyData(processID: Int32, secretKey: [UInt8])
    case parameterStatus(name: String, value: String)
    case readyForQuery(TransactionStatus)
    case rowDescription([FieldDescription])
    case dataRow(ArraySlice<UInt8>)
    case commandComplete(String)
    case emptyQueryResponse
    case errorResponse(ServerMessageFields)
    case noticeResponse(ServerMessageFields)
    case notification(NotificationMessage)
    case parseComplete
    case bindComplete
    case closeComplete
    case noData
    case portalSuspended
    case parameterDescription([UInt32])
    case copyInResponse(CopyFormat)
    case copyOutResponse(CopyFormat)
    case copyBothResponse(CopyFormat)
    case copyData(ArraySlice<UInt8>)
    case copyDone
    case negotiateProtocolVersion(newestMinor: Int32, unrecognizedOptions: [String])
    case functionCallResponse
    case unknown(type: UInt8)
}

/// A framed message: type byte plus payload (without the length word).
public struct RawMessage: Sendable {
    public let type: UInt8
    public let payload: ArraySlice<UInt8>

    public init(type: UInt8, payload: ArraySlice<UInt8>) {
        self.type = type
        self.payload = payload
    }

    /// Maximum number of columns a RowDescription may announce (PostgreSQL allows 1,664).
    static let maxFields = 4_096

    public func parse() throws -> BackendMessage {
        var reader = ByteReader(payload)
        switch type {
        case 0x52: // R
            return .authentication(try Self.authentication(&reader))
        case 0x4B: // K
            let pid = try reader.readInt32()
            let key = Array(reader.readRemaining())
            guard (4...256).contains(key.count) else { throw PostgresWireError.invalid("cancel key of \(key.count) bytes") }
            return .backendKeyData(processID: pid, secretKey: key)
        case 0x53: // S
            return .parameterStatus(name: try reader.readCString(), value: try reader.readCString())
        case 0x5A: // Z
            return .readyForQuery(try TransactionStatus(byte: try reader.readUInt8()))
        case 0x54: // T
            let count = Int(try reader.readInt16())
            guard (0...Self.maxFields).contains(count) else { throw PostgresWireError.invalid("field count \(count)") }
            var fields: [FieldDescription] = []
            fields.reserveCapacity(count)
            for _ in 0..<count {
                let name = try reader.readCString()
                let table = try reader.readUInt32()
                let column = try reader.readInt16()
                let type = try reader.readUInt32()
                let size = try reader.readInt16()
                let modifier = try reader.readInt32()
                let rawFormat = try reader.readInt16()
                guard let format = FormatCode(rawValue: rawFormat) else { throw PostgresWireError.invalid("format code \(rawFormat)") }
                fields.append(FieldDescription(name: name, tableOID: table, columnNumber: column, typeOID: type, typeSize: size,
                                               typeModifier: modifier, format: format))
            }
            return .rowDescription(fields)
        case 0x44: // D
            return .dataRow(payload)
        case 0x43: // C
            return .commandComplete(try reader.readCString())
        case 0x49: // I
            return .emptyQueryResponse
        case 0x45: // E
            return .errorResponse(try ServerMessageFields.parse(payload))
        case 0x4E: // N
            return .noticeResponse(try ServerMessageFields.parse(payload))
        case 0x41: // A
            return .notification(NotificationMessage(processID: try reader.readInt32(), channel: try reader.readCString(),
                                                     payload: try reader.readCString()))
        case 0x31: return .parseComplete
        case 0x32: return .bindComplete
        case 0x33: return .closeComplete
        case 0x6E: return .noData
        case 0x73: return .portalSuspended
        case 0x74: // t
            let count = Int(try reader.readInt16())
            guard (0...Int(Int16.max)).contains(count) else { throw PostgresWireError.invalid("parameter count \(count)") }
            var types: [UInt32] = []
            types.reserveCapacity(count)
            for _ in 0..<count { types.append(try reader.readUInt32()) }
            return .parameterDescription(types)
        case 0x47: return .copyInResponse(try Self.copyFormat(&reader))
        case 0x48: return .copyOutResponse(try Self.copyFormat(&reader))
        case 0x57: return .copyBothResponse(try Self.copyFormat(&reader))
        case 0x64: return .copyData(payload)
        case 0x63: return .copyDone
        case 0x76: // v
            let minor = try reader.readInt32()
            let count = Int(try reader.readInt32())
            guard (0...1_024).contains(count) else { throw PostgresWireError.invalid("option count \(count)") }
            var options: [String] = []
            for _ in 0..<count { options.append(try reader.readCString()) }
            return .negotiateProtocolVersion(newestMinor: minor, unrecognizedOptions: options)
        case 0x56: return .functionCallResponse
        default: return .unknown(type: type)
        }
    }

    private static func authentication(_ reader: inout ByteReader) throws -> AuthenticationRequest {
        let code = try reader.readInt32()
        switch code {
        case 0: return .ok
        case 3: return .cleartextPassword
        case 5: return .md5Password(salt: Array(try reader.readBytes(4)))
        case 10:
            var mechanisms: [String] = []
            while true {
                let name = try reader.readCString()
                if name.isEmpty { break }
                mechanisms.append(name)
                guard mechanisms.count <= 64 else { throw PostgresWireError.invalid("too many SASL mechanisms") }
            }
            return .sasl(mechanisms: mechanisms)
        case 11: return .saslContinue(Array(reader.readRemaining()))
        case 12: return .saslFinal(Array(reader.readRemaining()))
        default: return .unsupported(code)
        }
    }

    private static func copyFormat(_ reader: inout ByteReader) throws -> CopyFormat {
        let overall = try reader.readUInt8()
        let count = Int(try reader.readInt16())
        guard (0...Self.maxFields).contains(count) else { throw PostgresWireError.invalid("copy column count \(count)") }
        var formats: [FormatCode] = []
        formats.reserveCapacity(count)
        for _ in 0..<count {
            let raw = try reader.readInt16()
            guard let format = FormatCode(rawValue: raw) else { throw PostgresWireError.invalid("copy format \(raw)") }
            formats.append(format)
        }
        return CopyFormat(isBinary: overall == 1, columnFormats: formats)
    }
}

/// Splits a byte stream into backend messages. Bounded: a message larger than `maxMessageSize` throws.
public struct MessageDecoder: Sendable {
    public let maxMessageSize: Int
    private var buffer: [UInt8] = []
    private var readIndex = 0

    /// PostgreSQL never sends a single value larger than 1 GB; leave room for the row around it.
    public init(maxMessageSize: Int = (1 << 30) + (1 << 20)) {
        self.maxMessageSize = max(16, maxMessageSize)
    }

    public var bufferedByteCount: Int { buffer.count - readIndex }

    public mutating func append(_ bytes: [UInt8]) {
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    /// Next complete message, or `nil` when more bytes are needed.
    public mutating func next() throws -> RawMessage? {
        guard buffer.count - readIndex >= 5 else { return nil }
        let type = buffer[readIndex]
        var length = 0
        for offset in 1...4 { length = length << 8 | Int(buffer[readIndex + offset]) }
        guard length >= 4 else { throw PostgresWireError.invalid("message length \(length)") }
        guard length <= maxMessageSize else { throw PostgresWireError.oversized(length) }
        let total = 1 + length
        guard buffer.count - readIndex >= total else { return nil }
        let payload = buffer[(readIndex + 5)..<(readIndex + total)]
        readIndex += total
        return RawMessage(type: type, payload: payload)
    }

    /// Bytes after the last complete message (e.g. the server's TLS handshake after `S`, kept for diagnostics).
    public mutating func takeRemaining() -> [UInt8] {
        defer {
            buffer.removeAll(keepingCapacity: false)
            readIndex = 0
        }
        return Array(buffer[readIndex...])
    }

    private mutating func compactIfNeeded() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: buffer.capacity <= 1 << 20)
            readIndex = 0
        } else if readIndex > 64 * 1024, readIndex * 2 > buffer.count {
            buffer.removeSubrange(0..<readIndex)
            readIndex = 0
        }
    }
}

/// DataRow cell splitting.
public enum DataRow {
    /// Cells of a DataRow payload; `nil` entries are SQL NULL. Slices reference `payload`.
    public static func cells(_ payload: ArraySlice<UInt8>) throws -> [ArraySlice<UInt8>?] {
        var reader = ByteReader(payload)
        let count = Int(try reader.readInt16())
        guard (0...RawMessage.maxFields).contains(count) else { throw PostgresWireError.invalid("column count \(count)") }
        var cells: [ArraySlice<UInt8>?] = []
        cells.reserveCapacity(count)
        for _ in 0..<count {
            let length = try reader.readInt32()
            if length == -1 {
                cells.append(nil)
            } else {
                guard length >= 0 else { throw PostgresWireError.invalid("cell length \(length)") }
                cells.append(try reader.readBytes(Int(length)))
            }
        }
        return cells
    }

    public static func cells(_ payload: [UInt8]) throws -> [ArraySlice<UInt8>?] {
        try cells(payload[...])
    }
}

/// A CommandComplete tag (`INSERT 0 5`, `UPDATE 3`, `CREATE TABLE`).
public struct CommandTag: Sendable, Equatable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// Statement verb(s) without the counts (`INSERT`, `CREATE TABLE`).
    public var verb: String {
        let words = raw.split(separator: " ")
        let firstNumber = words.firstIndex { $0.allSatisfy(\.isNumber) } ?? words.endIndex
        return words[..<firstNumber].joined(separator: " ")
    }

    /// Rows affected or returned, for tags that carry a count.
    public var rowCount: Int? {
        let words = raw.split(separator: " ")
        guard let first = words.first, let last = words.last, words.count >= 2 else { return nil }
        switch first {
        case "INSERT", "UPDATE", "DELETE", "SELECT", "MOVE", "FETCH", "COPY", "MERGE":
            guard last.utf8.count <= 18 else { return nil }
            return Int(last)
        default:
            return nil
        }
    }

    public var description: String { raw }
}
