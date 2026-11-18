import Foundation

/// Wire format of a parameter or result column.
public enum FormatCode: Int16, Sendable, Equatable {
    case text = 0
    case binary = 1
}

/// A bound parameter value for the extended query protocol.
public enum BindValue: Sendable, Equatable {
    case null
    case text(String)
    case binary([UInt8])

    var format: FormatCode {
        if case .binary = self { return .binary }
        return .text
    }
}

/// What a Describe or Close message targets.
public enum DescribeTarget: UInt8, Sendable {
    case statement = 0x53 // S
    case portal = 0x50 // P
}

/// Encoders for every frontend message the client sends. Pure functions returning framed bytes.
public enum FrontendMessage {
    public static let protocolVersion30: Int32 = 196_608
    static let sslRequestCode: Int32 = 80_877_103
    static let cancelRequestCode: Int32 = 80_877_102

    /// `StartupMessage` (protocol 3.0). A parameter name or value with a NUL is refused (`PostgresWireError.nulCharacter`),
    /// as is any other message text below: the transport never changes what it is given.
    public static func startup(parameters: [(String, String)]) throws -> [UInt8] {
        var writer = ByteWriter(capacity: 128)
        writer.writeInt32(0)
        writer.writeInt32(protocolVersion30)
        for (name, value) in parameters {
            try writer.writeCString(name)
            try writer.writeCString(value)
        }
        writer.writeUInt8(0)
        writer.patchInt32(Int32(clamping: writer.bytes.count), at: 0)
        return writer.bytes
    }

    public static let sslRequest: [UInt8] = {
        var writer = ByteWriter(capacity: 8)
        writer.writeInt32(8)
        writer.writeInt32(sslRequestCode)
        return writer.bytes
    }()

    /// `CancelRequest`. Protocol 3.0 keys are 4 bytes; longer keys (protocol 3.2) are sent as received.
    public static func cancelRequest(processID: Int32, secretKey: [UInt8]) -> [UInt8] {
        var writer = ByteWriter(capacity: 16)
        writer.writeInt32(Int32(clamping: 12 + secretKey.count))
        writer.writeInt32(cancelRequestCode)
        writer.writeInt32(processID)
        writer.writeBytes(secretKey)
        return writer.bytes
    }

    public static func query(_ sql: String) throws -> [UInt8] {
        try message(0x51) { try $0.writeCString(sql) }
    }

    public static func parse(statement: String, query: String, parameterTypes: [UInt32] = []) throws -> [UInt8] {
        try message(0x50) { writer in
            try writer.writeCString(statement)
            try writer.writeCString(query)
            writer.writeInt16(Int16(clamping: parameterTypes.count))
            for type in parameterTypes.prefix(Int(Int16.max)) { writer.writeInt32(Int32(bitPattern: type)) }
        }
    }

    public static func bind(portal: String, statement: String, parameters: [BindValue], resultFormats: [FormatCode]) throws -> [UInt8] {
        try message(0x42) { writer in
            try writer.writeCString(portal)
            try writer.writeCString(statement)
            let values = parameters.prefix(Int(Int16.max))
            writer.writeInt16(Int16(clamping: values.count))
            for value in values { writer.writeInt16(value.format.rawValue) }
            writer.writeInt16(Int16(clamping: values.count))
            for value in values {
                switch value {
                case .null:
                    writer.writeInt32(-1)
                case let .text(text):
                    let bytes = Array(text.utf8)
                    writer.writeInt32(Int32(clamping: bytes.count))
                    writer.writeBytes(bytes)
                case let .binary(bytes):
                    writer.writeInt32(Int32(clamping: bytes.count))
                    writer.writeBytes(bytes)
                }
            }
            let formats = resultFormats.prefix(Int(Int16.max))
            writer.writeInt16(Int16(clamping: formats.count))
            for format in formats { writer.writeInt16(format.rawValue) }
        }
    }

    public static func describe(_ target: DescribeTarget, name: String) throws -> [UInt8] {
        try message(0x44) { writer in
            writer.writeUInt8(target.rawValue)
            try writer.writeCString(name)
        }
    }

    public static func execute(portal: String, maxRows: Int32) throws -> [UInt8] {
        try message(0x45) { writer in
            try writer.writeCString(portal)
            writer.writeInt32(max(0, maxRows))
        }
    }

    public static func close(_ target: DescribeTarget, name: String) throws -> [UInt8] {
        try message(0x43) { writer in
            writer.writeUInt8(target.rawValue)
            try writer.writeCString(name)
        }
    }

    public static let sync: [UInt8] = [0x53, 0, 0, 0, 4]
    public static let flush: [UInt8] = [0x48, 0, 0, 0, 4]
    public static let terminate: [UInt8] = [0x58, 0, 0, 0, 4]
    public static let copyDone: [UInt8] = [0x63, 0, 0, 0, 4]

    /// `PasswordMessage` (clear text or `md5…` hash).
    public static func password(_ text: String) throws -> [UInt8] {
        try message(0x70) { try $0.writeCString(text) }
    }

    public static func saslInitialResponse(mechanism: String, data: [UInt8]) throws -> [UInt8] {
        try message(0x70) { writer in
            try writer.writeCString(mechanism)
            writer.writeInt32(Int32(clamping: data.count))
            writer.writeBytes(data)
        }
    }

    public static func saslResponse(_ data: [UInt8]) -> [UInt8] {
        message(0x70) { $0.writeBytes(data) }
    }

    public static func copyFail(_ reason: String) throws -> [UInt8] {
        try message(0x66) { try $0.writeCString(reason) }
    }

    /// Frames a typed message: type byte, Int32 length (including itself), body.
    static func message(_ type: UInt8, _ body: (inout ByteWriter) throws -> Void) rethrows -> [UInt8] {
        var writer = ByteWriter(capacity: 64)
        writer.writeUInt8(type)
        writer.writeInt32(0)
        try body(&writer)
        writer.patchInt32(Int32(clamping: writer.bytes.count - 1), at: 1)
        return writer.bytes
    }
}
