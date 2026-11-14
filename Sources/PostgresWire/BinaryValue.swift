import Foundation

/// Converts binary-format values into the exact text PostgreSQL prints for them (DateStyle ISO,
/// IntervalStyle postgres, bytea_output hex, PostgreSQL 12+ float output), so the UI has a single
/// representation regardless of the wire format. Returns `nil` for unsupported types or malformed
/// input; never traps.
public enum BinaryValue {
    static let postgresEpochDays: Int64 = 10_957 // 2000-01-01 relative to 1970-01-01
    static let microsPerDay: Int64 = 86_400_000_000

    public static func canonicalText(_ bytes: ArraySlice<UInt8>, type: UInt32, timeZone: String) -> String? {
        var reader = ByteReader(bytes)
        func exact<T>(_ size: Int, _ read: (inout ByteReader) throws -> T) -> T? {
            guard bytes.count == size else { return nil }
            return try? read(&reader)
        }
        switch type {
        case 16: // bool
            return exact(1) { try $0.readUInt8() }.map { $0 == 0 ? "f" : "t" }
        case 17: // bytea
            return "\\x" + PostgresAuth.hex(bytes)
        case 18: // "char"
            guard bytes.count == 1, let byte = bytes.first else { return bytes.isEmpty ? "" : nil }
            return byte < 0x80 ? String(UnicodeScalar(byte)) : "\\" + String(byte, radix: 8)
        case 19, 25, 114, 705, 1042, 1043: // name, text, json, unknown, bpchar, varchar
            return String(decoding: bytes, as: UTF8.self)
        case 3802: // jsonb: version byte 1, then text
            guard bytes.first == 1 else { return nil }
            return String(decoding: bytes.dropFirst(), as: UTF8.self)
        case 21:
            return exact(2) { try $0.readInt16() }.map { String($0) }
        case 23:
            return exact(4) { try $0.readInt32() }.map { String($0) }
        case 20:
            return exact(8) { try $0.readInt64() }.map { String($0) }
        case 26, 28, 29: // oid, xid, cid
            return exact(4) { try $0.readUInt32() }.map { String($0) }
        case 5069: // xid8
            return exact(8) { try $0.readInt64() }.map { String(UInt64(bitPattern: $0)) }
        case 700:
            return exact(4) { try $0.readUInt32() }.map { FloatFormatter.format(Float(bitPattern: $0)) }
        case 701:
            return exact(8) { try $0.readInt64() }.map { FloatFormatter.format(Double(bitPattern: UInt64(bitPattern: $0))) }
        case 1700:
            return numeric(&reader)
        case 2950:
            guard bytes.count == 16 else { return nil }
            let hex = Array(PostgresAuth.hex(bytes))
            return String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
        case 1082:
            return exact(4) { try $0.readInt32() }.map(date)
        case 1083:
            return exact(8) { try $0.readInt64() }.flatMap { time(micros: $0) }
        case 1266:
            guard bytes.count == 12, let micros = try? reader.readInt64(), let zone = try? reader.readInt32(),
                  let clock = time(micros: micros) else { return nil }
            // PostgreSQL stores the zone as seconds *west* of UTC.
            return clock + zoneSuffix(offsetSeconds: -Int(zone))
        case 1114:
            return exact(8) { try $0.readInt64() }.map { timestamp(micros: $0, offsetSeconds: nil) }
        case 1184:
            return exact(8) { try $0.readInt64() }.map { micros in
                timestamp(micros: micros, offsetSeconds: offset(at: micros, timeZone: timeZone))
            }
        case 1186:
            guard bytes.count == 16, let micros = try? reader.readInt64(), let days = try? reader.readInt32(),
                  let months = try? reader.readInt32() else { return nil }
            return interval(micros: micros, days: days, months: months)
        case 869, 650:
            return inet(&reader, isCIDRType: type == 650)
        case 829:
            guard bytes.count == 6 else { return nil }
            return bytes.map { byte in (byte < 16 ? "0" : "") + String(byte, radix: 16) }.joined(separator: ":")
        default:
            return nil
        }
    }

    // MARK: numeric

    static func numeric(_ reader: inout ByteReader) -> String? {
        guard let count = try? reader.readInt16(), let weight = try? reader.readInt16(), let sign = try? reader.readUInt16(),
              let scale = try? reader.readInt16(), count >= 0, scale >= 0, reader.remaining == Int(count) * 2 else { return nil }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        case 0x0000, 0x4000: break
        default: return nil
        }
        var digits: [Int] = []
        digits.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let digit = try? reader.readInt16(), (0...9_999).contains(digit) else { return nil }
            digits.append(Int(digit))
        }
        var output = sign == 0x4000 ? "-" : ""
        let weightValue = Int(weight)
        func group(_ index: Int) -> Int { index >= 0 && index < digits.count ? digits[index] : 0 }
        if weightValue < 0 {
            output += "0"
        } else {
            for index in 0...weightValue {
                let value = group(index)
                output += index == 0 ? String(value) : pad4(value)
            }
        }
        if scale > 0 {
            output += "."
            var fraction = ""
            var index = weightValue + 1
            while fraction.count < Int(scale) {
                fraction += pad4(group(index))
                index += 1
            }
            output += fraction.prefix(Int(scale))
        }
        return output
    }

    static func pad4(_ value: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, 4 - text.count)) + text
    }

    // MARK: dates and times

    static func date(_ days: Int32) -> String {
        if days == Int32.max { return "infinity" }
        if days == Int32.min { return "-infinity" }
        let civil = civilFromDays(Int64(days) + postgresEpochDays)
        return formatDate(civil)
    }

    static func time(micros: Int64) -> String? {
        guard micros >= 0, micros <= microsPerDay else { return nil }
        return clock(micros: micros)
    }

    static func clock(micros: Int64) -> String {
        let seconds = micros / 1_000_000
        let fraction = micros % 1_000_000
        return two(seconds / 3600) + ":" + two(seconds / 60 % 60) + ":" + two(seconds % 60) + fractionText(fraction)
    }

    static func timestamp(micros: Int64, offsetSeconds: Int?) -> String {
        if micros == Int64.max { return "infinity" }
        if micros == Int64.min { return "-infinity" }
        let shifted = micros.addingReportingOverflow(Int64(offsetSeconds ?? 0) * 1_000_000)
        let local = shifted.overflow ? micros : shifted.partialValue
        let dayIndex = floorDivide(local, microsPerDay)
        let timeOfDay = local - dayIndex * microsPerDay
        let civil = civilFromDays(dayIndex + postgresEpochDays)
        var text = formatDate(civil, bcSuffix: false) + " " + clock(micros: timeOfDay)
        if let offsetSeconds { text += zoneSuffix(offsetSeconds: offsetSeconds) }
        if civil.year <= 0 { text += " BC" }
        return text
    }

    /// `+HH`, `+HH:MM` or `+HH:MM:SS` as PostgreSQL's EncodeTimezone.
    static func zoneSuffix(offsetSeconds: Int) -> String {
        let sign = offsetSeconds < 0 ? "-" : "+"
        let magnitude = abs(offsetSeconds)
        var text = sign + two(Int64(magnitude / 3600))
        let minutes = magnitude / 60 % 60
        let seconds = magnitude % 60
        if minutes != 0 || seconds != 0 { text += ":" + two(Int64(minutes)) }
        if seconds != 0 { text += ":" + two(Int64(seconds)) }
        return text
    }

    /// Offset of `timeZone` (a PostgreSQL TimeZone setting) at an instant; UTC when unknown to Foundation.
    static func offset(at micros: Int64, timeZone: String) -> Int {
        guard micros != Int64.max, micros != Int64.min, let zone = TimeZone(identifier: timeZone) ?? TimeZone(abbreviation: timeZone) else { return 0 }
        let seconds = Double(micros) / 1_000_000 + Double(postgresEpochDays * 86_400)
        guard seconds.isFinite, abs(seconds) < 1e14 else { return 0 }
        return zone.secondsFromGMT(for: Date(timeIntervalSince1970: seconds))
    }

    static func formatDate(_ civil: (year: Int64, month: Int64, day: Int64), bcSuffix: Bool = true) -> String {
        let year = civil.year > 0 ? civil.year : 1 - civil.year
        let yearText = String(year)
        let padded = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return padded + "-" + two(civil.month) + "-" + two(civil.day) + (bcSuffix && civil.year <= 0 ? " BC" : "")
    }

    /// Proleptic Gregorian date for days since 1970-01-01 (Howard Hinnant's algorithm), in Int64.
    static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = days + 719_468
        let era = floorDivide(z, 146_097)
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func floorDivide(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    static func two(_ value: Int64) -> String { value < 10 && value >= 0 ? "0" + String(value) : String(value) }

    /// `.ffffff` with trailing zeros removed; empty for whole seconds.
    static func fractionText(_ micros: Int64) -> String {
        guard micros != 0 else { return "" }
        var digits = String(abs(micros))
        digits = String(repeating: "0", count: max(0, 6 - digits.count)) + digits
        while digits.hasSuffix("0") { digits.removeLast() }
        return "." + digits
    }

    // MARK: interval

    /// IntervalStyle `postgres`, as PostgreSQL's EncodeInterval.
    static func interval(micros: Int64, days: Int32, months: Int32) -> String {
        var parts = ""
        var isZero = true
        var isBefore = false
        func add(_ value: Int64, _ unit: String) {
            guard value != 0 else { return }
            parts += (isZero ? "" : " ") + (isBefore && value > 0 ? "+" : "") + String(value) + " " + unit + (value != 1 ? "s" : "")
            isBefore = value < 0
            isZero = false
        }
        add(Int64(months) / 12, "year")
        add(Int64(months) % 12, "mon")
        add(Int64(days), "day")
        if isZero || micros != 0 {
            let magnitude = micros.magnitude
            let hours = magnitude / 3_600_000_000
            let minutes = magnitude / 60_000_000 % 60
            let seconds = magnitude / 1_000_000 % 60
            let fraction = Int64(magnitude % 1_000_000)
            let sign = micros < 0 ? "-" : (isBefore ? "+" : "")
            if !isZero { parts += " " }
            parts += sign + two(Int64(hours)) + ":" + two(Int64(minutes)) + ":" + two(Int64(seconds)) + fractionText(fraction)
        }
        return parts
    }

    // MARK: inet / cidr

    static func inet(_ reader: inout ByteReader, isCIDRType: Bool) -> String? {
        guard let family = try? reader.readUInt8(), let bits = try? reader.readUInt8(), let isCIDR = try? reader.readUInt8(),
              let length = try? reader.readUInt8(), let address = try? reader.readBytes(Int(length)), reader.isAtEnd else { return nil }
        let showPrefix: Bool
        let text: String
        switch (family, length) {
        case (2, 4):
            guard bits <= 32 else { return nil }
            text = address.map(String.init).joined(separator: ".")
            showPrefix = isCIDRType || isCIDR != 0 || bits != 32
        case (3, 16):
            guard bits <= 128 else { return nil }
            text = ipv6(Array(address))
            showPrefix = isCIDRType || isCIDR != 0 || bits != 128
        default:
            return nil
        }
        return showPrefix ? "\(text)/\(bits)" : text
    }

    static func ipv6(_ bytes: [UInt8]) -> String {
        var words: [Int] = []
        for index in stride(from: 0, to: 16, by: 2) { words.append(Int(bytes[index]) << 8 | Int(bytes[index + 1])) }
        // Longest run of zero words (at least two) is compressed to "::".
        var best = (start: -1, length: 0)
        var current = (start: -1, length: 0)
        for (index, word) in words.enumerated() {
            if word == 0 {
                current = current.start == -1 ? (index, 1) : (current.start, current.length + 1)
                if current.length > best.length { best = current }
            } else {
                current = (-1, 0)
            }
        }
        if best.length < 2 { best = (-1, 0) }
        // IPv4-mapped / compatible addresses keep the dotted quad.
        if best.start == 0, best.length == 6 || (best.length == 5 && words[5] == 0xFFFF) {
            let prefix = best.length == 5 ? "::ffff:" : "::"
            return prefix + bytes[12..<16].map(String.init).joined(separator: ".")
        }
        var output = ""
        var index = 0
        while index < 8 {
            if index == best.start {
                output += "::"
                index += best.length
                continue
            }
            if !output.isEmpty, !output.hasSuffix(":") { output += ":" }
            output += String(words[index], radix: 16)
            index += 1
        }
        return output
    }
}

/// PostgreSQL 12+ float output: shortest round-trip digits, `%g`-like switch to exponent notation.
enum FloatFormatter {
    static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return render("\(value)", precision: 15)
    }

    static func format(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        return render("\(value)", precision: 6)
    }

    /// Re-formats Swift's shortest representation (`1.5`, `1e-05`, `1.2345e+16`) the way PostgreSQL does.
    static func render(_ swift: String, precision: Int) -> String {
        var text = Substring(swift)
        var negative = false
        if text.first == "-" {
            negative = true
            text = text.dropFirst()
        }
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        var integerPart = mantissa
        var fractionPart: Substring = ""
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = mantissa[..<dot]
            fractionPart = mantissa[mantissa.index(after: dot)...]
        }
        var digits = Array(integerPart + fractionPart)
        var pointPosition = integerPart.count + exponent // digits before the decimal point
        while let first = digits.first, first == "0", digits.count > 1 {
            digits.removeFirst()
            pointPosition -= 1
        }
        while let last = digits.last, last == "0", digits.count > 1 { digits.removeLast() }
        let sign = negative ? "-" : ""
        if digits == ["0"] { return sign + "0" }
        let decimalExponent = pointPosition - 1
        if decimalExponent < -4 || decimalExponent >= precision {
            var body = String(digits[0])
            if digits.count > 1 { body += "." + String(digits[1...]) }
            let exponentText = String(abs(decimalExponent))
            return sign + body + "e" + (decimalExponent < 0 ? "-" : "+") + (exponentText.count < 2 ? "0" : "") + exponentText
        }
        if pointPosition <= 0 {
            return sign + "0." + String(repeating: "0", count: -pointPosition) + String(digits)
        }
        if pointPosition >= digits.count {
            return sign + String(digits) + String(repeating: "0", count: pointPosition - digits.count)
        }
        return sign + String(digits[..<pointPosition]) + "." + String(digits[pointPosition...])
    }
}
