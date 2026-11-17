import Foundation
import OrganizerAPI

/// Labels for wall-clock days and times, matching the web's `formatDayLabel` / `formatDue`
/// (web/src/lib/dates.ts): "Today", "Tomorrow", "Yesterday", a weekday within the coming
/// week, else "Oct 24" (with the year when it is not this year).
public enum DayLabels {
    public static func day(_ day: LocalDate, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = LocalDate.today(calendar: calendar, now: now)
        let diff = today.days(until: day, calendar: calendar)
        switch diff {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2..<7:
            var style = Date.FormatStyle.dateTime.weekday(.wide)
            style.timeZone = calendar.timeZone
            style.locale = calendar.locale ?? .current
            return day.date(in: calendar).formatted(style)
        default:
            let date = day.date(in: calendar)
            var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
            style.timeZone = calendar.timeZone
            style.locale = calendar.locale ?? .current
            if day.year != today.year { style = style.year() }
            return date.formatted(style)
        }
    }

    /// "3:00 PM" (locale formatted).
    public static func time(_ time: LocalTime, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return time.date(on: LocalDate(year: 2000, month: 1, day: 1), calendar: calendar).formatted(style)
    }

    /// A due label: "Today", "Tomorrow 3:00 PM", "Oct 24".
    public static func due(_ date: LocalDate, _ time: LocalTime?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let label = day(date, now: now, calendar: calendar)
        guard let time else { return label }
        return "\(label) \(self.time(time, calendar: calendar))"
    }

    /// "Sat, Oct 24", for previews of a parsed date.
    public static func long(_ day: LocalDate, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return day.date(in: calendar).formatted(style)
    }
}
