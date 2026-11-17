import Foundation

/// A wall-clock calendar day, as the API sends it: `"YYYY-MM-DD"` (a reminder's due date, a
/// challenge day). It has no time zone: "2026-10-24" is the 24th wherever you are.
///
/// Never turn one into a `Date` with a formatter in UTC. Use `date(in:)`, which gives local
/// midnight, and `LocalDate(date, calendar:)` to go back.
///
///     let due = LocalDate("2026-10-24")!          // from the wire
///     due < LocalDate.today()                     // overdue?
///     due.adding(days: 1)                         // 2026-10-25
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `"YYYY-MM-DD"`. Returns nil for anything else, including impossible days.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = Calendar(identifier: .gregorian)
        guard components.isValidDate else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// The day `date` falls on in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Today in `calendar`'s time zone.
    public static func today(calendar: Calendar = .current, now: Date = Date()) -> LocalDate {
        LocalDate(now, calendar: calendar)
    }

    /// `"YYYY-MM-DD"`, the wire form.
    public var string: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { string }

    /// Local midnight of this day in `calendar`'s time zone.
    public func date(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    /// This day plus `days` (negative goes back).
    public func adding(days: Int, calendar: Calendar = .current) -> LocalDate {
        LocalDate(calendar.date(byAdding: .day, value: days, to: date(in: calendar))!, calendar: calendar)
    }

    /// Whole days from `self` to `other` (positive when `other` is later).
    public func days(until other: LocalDate, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: date(in: calendar), to: other.date(in: calendar)).day!
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

extension LocalDate: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LocalDate(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected YYYY-MM-DD, got \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

/// A wall-clock time of day, as the API sends it: `"HH:MM:SS"` from the server, `"HH:MM"` on
/// the way in (both parse). Minute precision; seconds are dropped.
public struct LocalTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Parses `"HH:MM"` or `"HH:MM:SS"` (fractional seconds allowed and ignored).
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        if parts.count == 3 {
            guard let seconds = Double(parts[2]), (0..<61).contains(seconds) else { return nil }
        }
        self.init(hour: hour, minute: minute)
    }

    /// The time of day `date` shows in `calendar`'s time zone.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        self.init(hour: parts.hour!, minute: parts.minute!)
    }

    /// `"HH:MM"`, the wire form the server accepts.
    public var string: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public var description: String { string }

    /// This time on `day`, in `calendar`'s time zone.
    public func date(on day: LocalDate, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))!
    }

    public static func < (lhs: LocalTime, rhs: LocalTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}

extension LocalTime: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = LocalTime(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Expected HH:MM or HH:MM:SS, got \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}
