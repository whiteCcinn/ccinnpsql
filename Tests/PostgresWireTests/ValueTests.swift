import Foundation
import Testing
@testable import PostgresWire

@Suite("Binary value decoding")
struct BinaryValueTests {
    func text(_ type: PostgresType, _ bytes: [UInt8], timeZone: String = "UTC") -> String? {
        BinaryValue.canonicalText(bytes[...], type: type.oid, timeZone: timeZone)
    }

    @Test func integersBooleansAndOids() {
        #expect(text(.bool, [1]) == "t")
        #expect(text(.bool, [0]) == "f")
        #expect(text(.int2, int16(-32768)) == "-32768")
        #expect(text(.int4, int32(2_147_483_647)) == "2147483647")
        #expect(text(.int8, int64(Int64.min)) == "-9223372036854775808")
        #expect(text(.oid, int32(-1)) == "4294967295")
        #expect(text(.int4, [1, 2]) == nil) // wrong width: not decodable, never a trap
    }

    @Test func floatsUseShortestRoundTripLikePostgres12() {
        #expect(text(.float8, int64(Int64(bitPattern: (0.1).bitPattern))) == "0.1")
        #expect(text(.float8, int64(Int64(bitPattern: (100.0).bitPattern))) == "100")
        #expect(text(.float8, int64(Int64(bitPattern: (1e15).bitPattern))) == "1e+15")
        #expect(text(.float8, int64(Int64(bitPattern: (123456789012345.0).bitPattern))) == "123456789012345")
        #expect(text(.float8, int64(Int64(bitPattern: (0.0001).bitPattern))) == "0.0001")
        #expect(text(.float8, int64(Int64(bitPattern: (0.00001).bitPattern))) == "1e-05")
        #expect(text(.float8, int64(Int64(bitPattern: (-2.5e-300).bitPattern))) == "-2.5e-300")
        #expect(text(.float8, int64(Int64(bitPattern: Double.infinity.bitPattern))) == "Infinity")
        #expect(text(.float8, int64(Int64(bitPattern: (-Double.infinity).bitPattern))) == "-Infinity")
        #expect(text(.float8, int64(Int64(bitPattern: Double.nan.bitPattern))) == "NaN")
        #expect(text(.float8, int64(Int64(bitPattern: (0.30000000000000004).bitPattern))) == "0.30000000000000004")
        #expect(text(.float4, int32(Int32(bitPattern: Float(1.5).bitPattern))) == "1.5")
        #expect(text(.float4, int32(Int32(bitPattern: Float(100000).bitPattern))) == "100000")
        #expect(text(.float4, int32(Int32(bitPattern: Float(1e6).bitPattern))) == "1e+06")
        #expect(text(.float4, int32(Int32(bitPattern: Float(-0.0).bitPattern))) == "-0")
    }

    @Test func numeric() {
        func numeric(_ weight: Int16, _ sign: UInt16, _ dscale: Int16, _ digits: [Int16]) -> [UInt8] {
            int16(Int16(digits.count)) + int16(weight) + withUnsafeBytes(of: sign.bigEndian, Array.init) + int16(dscale) + digits.flatMap { int16($0) }
        }
        #expect(text(.numeric, numeric(0, 0, 0, [])) == "0")
        #expect(text(.numeric, numeric(0, 0, 2, [])) == "0.00")
        #expect(text(.numeric, numeric(1, 0, 0, [12, 3456])) == "123456")
        #expect(text(.numeric, numeric(0, 0x4000, 3, [12, 3400])) == "-12.340")
        #expect(text(.numeric, numeric(-1, 0, 5, [100])) == "0.01000")
        #expect(text(.numeric, numeric(-2, 0, 6, [500])) == "0.000005")
        #expect(text(.numeric, numeric(2, 0, 0, [1])) == "100000000")
        #expect(text(.numeric, numeric(0, 0xC000, 0, [])) == "NaN")
        #expect(text(.numeric, numeric(0, 0xD000, 0, [])) == "Infinity")
        #expect(text(.numeric, numeric(0, 0xF000, 0, [])) == "-Infinity")
        #expect(text(.numeric, numeric(0, 0, 0, [10_000])) == nil) // digit out of range
        #expect(text(.numeric, numeric(0, 0x1234, 0, [1])) == nil)
        #expect(text(.numeric, int16(5) + int16(0)) == nil)
    }

    @Test func textLikeTypes() {
        #expect(text(.text, Array("héllo".utf8)) == "héllo")
        #expect(text(.varchar, Array("x".utf8)) == "x")
        #expect(text(.name, Array("pg_class".utf8)) == "pg_class")
        #expect(text(.json, Array("{\"a\":1}".utf8)) == "{\"a\":1}")
        #expect(text(.jsonb, [1] + Array("{\"a\": 1}".utf8)) == "{\"a\": 1}")
        #expect(text(.jsonb, [2] + Array("{}".utf8)) == nil)
        #expect(text(.bytea, [0xDE, 0xAD, 0x00]) == "\\xdead00")
        #expect(text(.bytea, []) == "\\x")
        #expect(text(.uuid, [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0])
            == "12345678-9abc-def0-1234-56789abcdef0")
        #expect(text(.char, [0x41]) == "A")
    }

    @Test func datesAndTimes() {
        #expect(text(.date, int32(0)) == "2000-01-01")
        #expect(text(.date, int32(-1)) == "1999-12-31")
        #expect(text(.date, int32(8_766)) == "2024-01-01")
        #expect(text(.date, int32(-730_119)) == "0001-01-01")
        #expect(text(.date, int32(-730_120)) == "0001-12-31 BC")
        #expect(text(.date, int32(Int32.max)) == "infinity")
        #expect(text(.date, int32(Int32.min)) == "-infinity")
        #expect(text(.time, int64(0)) == "00:00:00")
        #expect(text(.time, int64(45_296_789_000)) == "12:34:56.789")
        #expect(text(.timetz, int64(3_600_000_000) + int32(-19_800)) == "01:00:00+05:30")
        #expect(text(.timetz, int64(0) + int32(18_000)) == "00:00:00-05")
        #expect(text(.timestamp, int64(0)) == "2000-01-01 00:00:00")
        #expect(text(.timestamp, int64(758_200_496_123_456)) == "2024-01-10 11:14:56.123456")
        #expect(text(.timestamp, int64(-1)) == "1999-12-31 23:59:59.999999")
        #expect(text(.timestamp, int64(Int64.max)) == "infinity")
        #expect(text(.timestamp, int64(Int64.min)) == "-infinity")
        #expect(text(.timestamptz, int64(758_200_496_000_000)) == "2024-01-10 11:14:56+00")
        #expect(text(.timestamptz, int64(758_200_496_500_000), timeZone: "Asia/Kolkata") == "2024-01-10 16:44:56.5+05:30")
        #expect(text(.timestamptz, int64(758_200_496_000_000), timeZone: "America/New_York") == "2024-01-10 06:14:56-05")
        #expect(text(.timestamptz, int64(0), timeZone: "Not/AZone") == "2000-01-01 00:00:00+00")
    }

    @Test func intervalsUsePostgresStyle() {
        func interval(_ micros: Int64, _ days: Int32, _ months: Int32) -> String? {
            text(.interval, int64(micros) + int32(days) + int32(months))
        }
        #expect(interval(0, 0, 0) == "00:00:00")
        #expect(interval(14_706_789_000, 3, 14) == "1 year 2 mons 3 days 04:05:06.789")
        #expect(interval(-14_706_000_000, 3, -14) == "-1 years -2 mons +3 days -04:05:06")
        #expect(interval(0, 1, 0) == "1 day")
        #expect(interval(0, -1, 1) == "1 mon -1 days")
        #expect(interval(7_200_000_000, -1, 0) == "-1 days +02:00:00")
        #expect(interval(-1_000_000, 0, 0) == "-00:00:01")
        #expect(interval(1_500_000, 3, 0) == "3 days 00:00:01.5")
        #expect(interval(360_000_000_000, 0, 0) == "100:00:00")
        #expect(interval(0, 0, 24) == "2 years")
    }

    @Test func networkTypes() {
        #expect(text(.inet, [2, 32, 0, 4, 192, 168, 1, 10]) == "192.168.1.10")
        #expect(text(.inet, [2, 24, 0, 4, 10, 0, 0, 1]) == "10.0.0.1/24")
        #expect(text(.cidr, [2, 32, 1, 4, 10, 0, 0, 1]) == "10.0.0.1/32")
        #expect(text(.inet, [3, 128, 0, 16] + [0x20, 0x01, 0x0D, 0xB8] + [UInt8](repeating: 0, count: 11) + [1]) == "2001:db8::1")
        #expect(text(.inet, [3, 128, 0, 16] + [UInt8](repeating: 0, count: 15) + [1]) == "::1")
        #expect(text(.inet, [3, 128, 0, 16] + [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 1, 2, 3, 4]) == "::ffff:1.2.3.4")
        #expect(text(.cidr, [3, 64, 1, 16] + [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 1] + [UInt8](repeating: 0, count: 8)) == "2001:db8:0:1::/64")
        #expect(text(.inet, [2, 32, 0, 3, 1, 2, 3]) == nil)
        #expect(text(.macaddr, [0x08, 0x00, 0x2B, 0x01, 0x02, 0x03]) == "08:00:2b:01:02:03")
    }

    @Test func unsupportedTypesReturnNil() {
        #expect(BinaryValue.canonicalText([1, 2, 3][...], type: 1007, timeZone: "UTC") == nil) // int4[]
        #expect(!PostgresType.supportsBinary(1007))
        #expect(PostgresType.supportsBinary(PostgresType.timestamptz.oid))
    }

    @Test func fuzzedBinaryNeverTraps() {
        var generator = SplitMix64(seed: 99)
        let types = PostgresType.binaryDecodable.map(\.oid)
        for _ in 0..<30_000 {
            let length = Int(generator.next() % 40)
            var bytes: [UInt8] = []
            for _ in 0..<length { bytes.append(UInt8(truncatingIfNeeded: generator.next())) }
            let type = types[Int(generator.next() % UInt64(types.count))]
            _ = BinaryValue.canonicalText(bytes[...], type: type, timeZone: "Europe/Berlin")
        }
    }
}

@Suite("Text value parsing")
struct TextValueTests {
    @Test func numbersAndBooleans() {
        #expect(PostgresText.integer("42") == 42)
        #expect(PostgresText.integer("99999999999999999999") == nil)
        #expect(PostgresText.double("1.5e3") == 1500)
        #expect(PostgresText.double("Infinity") == nil)
        #expect(PostgresText.double("NaN") == nil)
        #expect(PostgresText.double("abc") == nil)
        #expect(PostgresText.bool("t") == true)
        #expect(PostgresText.bool("false") == false)
        #expect(PostgresText.bool("maybe") == nil)
    }

    @Test func timestampsAsUTCInstants() throws {
        let plain = try #require(PostgresText.dateTime("2024-01-11 11:14:56.5"))
        #expect(plain.timeIntervalSince1970 == 1_704_971_696.5)
        let zoned = try #require(PostgresText.dateTime("2024-01-11 16:44:56+05:30"))
        #expect(zoned.timeIntervalSince1970 == 1_704_971_696)
        let negative = try #require(PostgresText.dateTime("2024-01-11 06:14:56-05"))
        #expect(negative.timeIntervalSince1970 == 1_704_971_696)
        #expect(PostgresText.dateTime("2024-01-11")?.timeIntervalSince1970 == 1_704_931_200)
        #expect(PostgresText.dateTime("infinity") == nil)
        #expect(PostgresText.dateTime("0044-03-15 BC") == nil)
        #expect(PostgresText.dateTime("2024-13-01") == nil)
        #expect(PostgresText.dateTime("2024-01-11T11:14:56Z")?.timeIntervalSince1970 == 1_704_971_696)
    }

    @Test func byteaHexAndEscape() {
        #expect(PostgresText.bytea("\\xdead00") == [0xDE, 0xAD, 0x00])
        #expect(PostgresText.bytea("\\xzz") == nil)
        #expect(PostgresText.bytea("a\\\\b\\001") == [0x61, 0x5C, 0x62, 0x01])
    }

    @Test func intervalSeconds() {
        #expect(PostgresText.intervalSeconds("00:00:01.5") == 1.5)
        #expect(PostgresText.intervalSeconds("1 day 02:00:00") == 93_600)
        #expect(PostgresText.intervalSeconds("-00:00:02") == -2)
        #expect(PostgresText.intervalSeconds("1 mon") == nil)
    }

    @Test func fuzzedTextNeverTraps() {
        var generator = SplitMix64(seed: 5)
        let alphabet = Array("0123456789-+:. TZe\\x BCinfity".utf8)
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 40)
            var bytes: [UInt8] = []
            for _ in 0..<length { bytes.append(alphabet[Int(generator.next() % UInt64(alphabet.count))]) }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = PostgresText.dateTime(text)
            _ = PostgresText.bytea(text)
            _ = PostgresText.double(text)
            _ = PostgresText.intervalSeconds(text)
        }
    }
}

@Suite("Type registry")
struct TypeRegistryTests {
    @Test func namesAndKinds() {
        #expect(PostgresType.name(of: 23) == "int4")
        #expect(PostgresType.name(of: 1184) == "timestamptz")
        #expect(PostgresType.name(of: 1007) == "_int4")
        #expect(PostgresType.name(of: 999_999) == nil)
        #expect(PostgresType.kind(of: 20) == .integer)
        #expect(PostgresType.kind(of: 1700) == .decimal)
        #expect(PostgresType.kind(of: 701) == .float)
        #expect(PostgresType.kind(of: 1114) == .dateTime)
        #expect(PostgresType.kind(of: 1082) == .date)
        #expect(PostgresType.kind(of: 3802) == .json)
        #expect(PostgresType.kind(of: 17) == .binary)
        #expect(PostgresType.kind(of: 16) == .boolean)
        #expect(PostgresType.kind(of: 1007) == .array)
        #expect(PostgresType.kind(of: 999_999) == .text)
    }
}
