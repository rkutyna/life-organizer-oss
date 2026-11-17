import Foundation

/// The JSON coding the API speaks.
///
/// - Datetimes are ISO 8601 (`2026-10-24T04:25:37.903842Z`): with or without fractional
///   seconds, `Z` or an offset. One without an offset is read as UTC (the server stores UTC).
/// - Wall-clock dates and times are `LocalDate` / `LocalTime`, which code themselves.
/// - Keys are snake_case on the wire; the generated types carry their own CodingKeys, so no
///   key strategy is set here.
public enum APIJSON {
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseDateTime(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Expected an ISO 8601 datetime, got \(raw)")
            }
            return date
        }
        return decoder
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDateTime(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// `2026-10-24T04:25:37.903Z` (UTC, milliseconds).
    public static func formatDateTime(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt).format(date)
    }

    /// Parses `YYYY-MM-DDTHH:MM[:SS[.fraction]][Z|±HH:MM|±HHMM]` (a space works for the T).
    public static func parseDateTime(_ raw: String) -> Date? {
        let chars = Array(raw.utf8)
        var index = 0

        func number(_ digits: Int) -> Int? {
            guard index + digits <= chars.count else { return nil }
            var value = 0
            for offset in 0..<digits {
                let char = chars[index + offset]
                guard char >= 48, char <= 57 else { return nil }
                value = value * 10 + Int(char - 48)
            }
            index += digits
            return value
        }
        func expect(_ char: UInt8) -> Bool {
            guard index < chars.count, chars[index] == char else { return false }
            index += 1
            return true
        }

        guard let year = number(4), expect(UInt8(ascii: "-")),
              let month = number(2), expect(UInt8(ascii: "-")),
              let day = number(2)
        else { return nil }
        guard index < chars.count, chars[index] == UInt8(ascii: "T") || chars[index] == UInt8(ascii: " ")
        else { return nil }
        index += 1
        guard let hour = number(2), expect(UInt8(ascii: ":")), let minute = number(2) else { return nil }

        var second = 0
        var fraction = 0.0
        if expect(UInt8(ascii: ":")) {
            guard let value = number(2) else { return nil }
            second = value
            if expect(UInt8(ascii: ".")) || expect(UInt8(ascii: ",")) {
                var scale = 0.1
                var digits = 0
                while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                    fraction += Double(chars[index] - 48) * scale
                    scale /= 10
                    index += 1
                    digits += 1
                }
                guard digits > 0 else { return nil }
            }
        }

        var offsetSeconds = 0
        if index < chars.count {
            let sign = chars[index]
            if sign == UInt8(ascii: "Z") || sign == UInt8(ascii: "z") {
                index += 1
            } else if sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                index += 1
                guard let hours = number(2) else { return nil }
                _ = expect(UInt8(ascii: ":"))
                let minutes = number(2) ?? 0
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == UInt8(ascii: "-") ? -1 : 1)
            } else {
                return nil
            }
        }
        guard index == chars.count else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard components.isValidDate(in: calendar), let base = calendar.date(from: components)
        else { return nil }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }
}
