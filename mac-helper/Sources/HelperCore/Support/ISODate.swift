import Foundation

/// ISO-8601 dates on the wire. Output always carries a UTC offset (the Mac's own by default,
/// `2026-10-18T18:01:57-04:00`), which keeps all-day events on their local calendar day: the
/// server reads an all-day value's day from the date as sent.
public enum ISODate {
    private static let lock = NSLock()

    // Formatters are not Sendable; every use holds `lock`.
    nonisolated(unsafe) private static let output: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        lock.lock(); defer { lock.unlock() }
        output.timeZone = timeZone
        var s = output.string(from: date)
        // ISO8601DateFormatter writes UTC as `Z`; spell it as an offset like every other zone.
        if s.hasSuffix("Z") { s = String(s.dropLast()) + "+00:00" }
        return s
    }

    /// Parses `2026-10-18T21:44:20.975Z`, `2026-10-18T21:44:20Z`, or with an offset. Python's
    /// `isoformat()` writes microseconds (`.123456`); those are cut to milliseconds first.
    public static func parse(_ s: String) -> Date? {
        let text = trimFraction(s)
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    /// `...T12:00:00.123456+00:00` -> `...T12:00:00.123+00:00`.
    static func trimFraction(_ s: String) -> String {
        guard let dot = s.firstIndex(of: "."), s[..<dot].contains("T") else { return s }
        let digitsEnd = s[s.index(after: dot)...].firstIndex { !$0.isNumber } ?? s.endIndex
        let digits = s[s.index(after: dot)..<digitsEnd]
        guard digits.count > 3 else { return s }
        return String(s[..<s.index(after: dot)]) + digits.prefix(3) + s[digitsEnd...]
    }
}
