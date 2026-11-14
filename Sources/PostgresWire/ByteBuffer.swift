import Foundation

/// Every malformed-input failure of the protocol layer. Parsers throw these instead of trapping.
public enum PostgresWireError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Fewer bytes than a field needs.
    case truncated(String)
    /// A length, count or code outside its legal range.
    case invalid(String)
    /// A message larger than the configured bound.
    case oversized(Int)
    /// Authentication could not proceed (bad server data, unsupported mechanism, failed verification).
    case authentication(String)

    public var description: String {
        switch self {
        case let .truncated(what): "Truncated protocol message (\(what))"
        case let .invalid(what): "Invalid protocol message (\(what))"
        case let .oversized(size): "Protocol message of \(size) bytes exceeds the limit"
        case let .authentication(message): message
        }
    }
}

/// Bounds-checked big-endian reader over a byte slice. Never traps on short or hostile input.
public struct ByteReader: Sendable {
    public let bytes: ArraySlice<UInt8>
    public private(set) var index: Int

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    public init(_ bytes: [UInt8]) {
        self.init(bytes[...])
    }

    public var remaining: Int { bytes.endIndex - index }
    public var isAtEnd: Bool { index >= bytes.endIndex }

    private mutating func take(_ count: Int, _ what: @autoclosure () -> String) throws -> ArraySlice<UInt8> {
        guard count >= 0 else { throw PostgresWireError.invalid("negative length for \(what())") }
        guard count <= remaining else { throw PostgresWireError.truncated(what()) }
        let slice = bytes[index..<(index + count)]
        index += count
        return slice
    }

    public mutating func readUInt8() throws -> UInt8 {
        guard index < bytes.endIndex else { throw PostgresWireError.truncated("byte") }
        defer { index += 1 }
        return bytes[index]
    }

    public mutating func readInt16() throws -> Int16 {
        let slice = try take(2, "int16")
        return Int16(bitPattern: UInt16(slice[slice.startIndex]) << 8 | UInt16(slice[slice.startIndex + 1]))
    }

    public mutating func readUInt16() throws -> UInt16 {
        UInt16(bitPattern: try readInt16())
    }

    public mutating func readInt32() throws -> Int32 {
        let slice = try take(4, "int32")
        var value: UInt32 = 0
        for byte in slice { value = value << 8 | UInt32(byte) }
        return Int32(bitPattern: value)
    }

    public mutating func readUInt32() throws -> UInt32 {
        UInt32(bitPattern: try readInt32())
    }

    public mutating func readInt64() throws -> Int64 {
        let slice = try take(8, "int64")
        var value: UInt64 = 0
        for byte in slice { value = value << 8 | UInt64(byte) }
        return Int64(bitPattern: value)
    }

    public mutating func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
        try take(count, "\(count) bytes")
    }

    public mutating func readRemaining() -> ArraySlice<UInt8> {
        defer { index = bytes.endIndex }
        return bytes[index...]
    }

    /// NUL-terminated string; invalid UTF-8 is replaced, a missing terminator throws.
    public mutating func readCString() throws -> String {
        guard let end = bytes[index...].firstIndex(of: 0) else { throw PostgresWireError.truncated("unterminated string") }
        let text = String(decoding: bytes[index..<end], as: UTF8.self)
        index = end + 1
        return text
    }
}

/// Big-endian writer used to build frontend messages.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }

    public mutating func writeInt16(_ value: Int16) {
        let raw = UInt16(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: raw >> 8))
        bytes.append(UInt8(truncatingIfNeeded: raw))
    }

    public mutating func writeInt32(_ value: Int32) {
        let raw = UInt32(bitPattern: value)
        bytes.append(UInt8(truncatingIfNeeded: raw >> 24))
        bytes.append(UInt8(truncatingIfNeeded: raw >> 16))
        bytes.append(UInt8(truncatingIfNeeded: raw >> 8))
        bytes.append(UInt8(truncatingIfNeeded: raw))
    }

    public mutating func writeBytes<S: Sequence>(_ data: S) where S.Element == UInt8 { bytes.append(contentsOf: data) }

    /// Writes `text` with NUL bytes removed (they cannot be represented) and a terminating NUL.
    public mutating func writeCString(_ text: String) {
        for byte in text.utf8 where byte != 0 { bytes.append(byte) }
        bytes.append(0)
    }

    /// Patches a big-endian Int32 at `offset` (used for message lengths).
    mutating func patchInt32(_ value: Int32, at offset: Int) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        let raw = UInt32(bitPattern: value)
        bytes[offset] = UInt8(truncatingIfNeeded: raw >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: raw >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: raw >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: raw)
    }
}
