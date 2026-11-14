import Foundation

/// Typed parsing of text-format values (as PostgreSQL prints them). Used by sorting, charts, export
/// and metadata accessors; every function returns `nil` instead of trapping.
public enum PostgresText {
    public static func integer(_ text: String) -> Int64? {
        guard text.utf8.count <= 20 else { return nil }
        return Int64(text)
    }

    /// Finite numbers only (`NaN`/`Infinity` → nil).
    public static func double(_ text: String) -> Double? {
        guard let first = text.utf8.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+")
            || first == UInt8(ascii: ".") || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) else { return nil }
        guard text.utf8.count <= 400, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    public static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "t", "true", "on", "yes", "y", "1": true
        case "f", "false", "off", "no", "n", "0": false
        default: nil
        }
    }

    /// `YYYY-MM-DD[ HH:MM:SS[.ffffff]][±HH[:MM[:SS]]|Z]` as an instant. Values without a zone are read
    /// as UTC (charts stay free of DST artefacts); BC dates and infinities return nil.
    public static func dateTime(_ text: String) -> Date? {
        let bytes = Array(text.utf8.prefix(48))
        guard bytes.count >= 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
              (1...12).contains(month), (1...31).contains(day), year >= 1 else { return nil }
        var seconds = Double(BinaryValue.daysFromCivil(year: year, month: month, day: day)) * 86_400
        var index = 10
        if index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: "T") {
            guard bytes.count >= 19, bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
                  let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2), let second = number(bytes, 17, 2),
                  hour <= 24, minute < 60, second < 61 else { return nil }
            seconds += Double(hour * 3600 + minute * 60 + second)
            index = 19
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                var scale = 0.1
                var fraction = 0.0
                while index < bytes.count, let digit = digitValue(bytes[index]) {
                    fraction += Double(digit) * scale
                    scale /= 10
                    index += 1
                }
                seconds += fraction
            }
            if index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "Z"):
                    index += 1
                case UInt8(ascii: "+"), UInt8(ascii: "-"):
                    let sign: Double = bytes[index] == UInt8(ascii: "-") ? -1 : 1
                    guard let hours = number(bytes, index + 1, 2) else { return nil }
                    var offset = Double(hours * 3600)
                    index += 3
                    if index < bytes.count, bytes[index] == UInt8(ascii: ":"), let minutes = number(bytes, index + 1, 2) {
                        offset += Double(minutes * 60)
                        index += 3
                        if index < bytes.count, bytes[index] == UInt8(ascii: ":"), let secs = number(bytes, index + 1, 2) {
                            offset += Double(secs)
                            index += 3
                        }
                    }
                    seconds -= sign * offset
                default:
                    return nil
                }
            }
        }
        guard index == bytes.count else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// bytea in hex (`\x…`) or escape format.
    public static func bytea(_ text: String) -> [UInt8]? {
        let bytes = Array(text.utf8)
        if bytes.count >= 2, bytes[0] == UInt8(ascii: "\\"), bytes[1] == UInt8(ascii: "x") {
            let hex = bytes[2...].filter { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\n") }
            guard hex.count % 2 == 0 else { return nil }
            var output: [UInt8] = []
            output.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                guard let high = hexValue(hex[index]), let low = hexValue(hex[index + 1]) else { return nil }
                output.append(high << 4 | low)
                index += 2
            }
            return output
        }
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte != UInt8(ascii: "\\") {
                output.append(byte)
                index += 1
            } else if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\\") {
                output.append(byte)
                index += 2
            } else if index + 3 < bytes.count, let a = octal(bytes[index + 1]), let b = octal(bytes[index + 2]), let c = octal(bytes[index + 3]),
                      a <= 3 {
                output.append(a << 6 | b << 3 | c)
                index += 4
            } else {
                return nil
            }
        }
        return output
    }

    /// Seconds of an interval that has no months (`1 day 02:00:00`, `-00:00:02`, `00:00:01.5`); nil otherwise.
    public static func intervalSeconds(_ text: String) -> Double? {
        var total = 0.0
        let words = text.split(separator: " ")
        guard !words.isEmpty, words.count <= 8 else { return nil }
        var index = 0
        while index < words.count {
            let word = words[index]
            if word.contains(":") {
                var clock = Substring(word)
                var sign = 1.0
                if clock.first == "-" {
                    sign = -1
                    clock = clock.dropFirst()
                } else if clock.first == "+" {
                    clock = clock.dropFirst()
                }
                let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let secs = Double(parts[2]),
                      hours.isFinite, secs.isFinite else { return nil }
                total += sign * (hours * 3600 + minutes * 60 + secs)
                index += 1
            } else {
                guard index + 1 < words.count, let value = Double(word), value.isFinite else { return nil }
                let unit = words[index + 1]
                guard unit == "day" || unit == "days" else { return nil }
                total += value * 86_400
                index += 2
            }
        }
        return total.isFinite ? total : nil
    }

    // MARK: Helpers

    static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start >= 0, start + length <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<(start + length)] {
            guard let digit = digitValue(byte) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    static func digitValue(_ byte: UInt8) -> Int? {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") ? Int(byte - UInt8(ascii: "0")) : nil
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    static func octal(_ byte: UInt8) -> UInt8? {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "7") ? byte - UInt8(ascii: "0") : nil
    }
}

extension BinaryValue {
    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
