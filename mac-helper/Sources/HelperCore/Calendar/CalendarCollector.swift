import Foundation

public enum CalendarError: Error, CustomStringConvertible {
    case notAuthorized(String)

    public var description: String {
        switch self {
        case .notAuthorized(let s):
            return "calendar access is \(s); the LaunchAgent asks on first run (approve the prompt), or turn it on in System Settings > Privacy & Security > Calendars"
        }
    }
}

/// Where calendars and events come from: EventKit (`EventKitCalendarSource`), or a fake in tests.
public protocol CalendarSource: AnyObject {
    func calendars() -> [CalendarInfo]
    /// Occurrences overlapping [start, end), recurring events expanded. May hold duplicates.
    func events(from start: Date, to end: Date) -> [CalendarEvent]
}

/// Every calendar in Calendar.app (all accounts) -> `/api/ingest/calendar`. Read-only; event
/// notes are never read.
public final class CalendarCollector {
    private let source: CalendarSource
    private let config: HelperConfig.Calendar
    private let calendar: Foundation.Calendar

    /// `calendar` decides local days (window bounds, all-day dates): the Mac's own by default.
    public init(source: CalendarSource, config: HelperConfig.Calendar, calendar: Foundation.Calendar = .current) {
        self.source = source
        self.config = config
        self.calendar = calendar
    }

    /// Window on local-day boundaries so it (and the payload hash) only moves once a day.
    public static func window(now: Date, pastDays: Int, futureDays: Int, calendar: Foundation.Calendar = .current) -> CalendarBody.Window {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -max(0, pastDays), to: today)!
        let end = calendar.date(byAdding: .day, value: max(0, futureDays) + 1, to: today)!
        return CalendarBody.Window(start: start, end: end)
    }

    public func collect(now: Date = Date()) -> CalendarBody {
        let window = Self.window(now: now, pastDays: config.past_days, futureDays: config.future_days, calendar: calendar)
        let infos = source.calendars().sorted { ($0.account ?? "", $0.title, $0.id) < ($1.account ?? "", $1.title, $1.id) }
        var seen = Set<String>()
        var events: [CalendarEvent] = []
        for raw in source.events(from: window.start, to: window.end) {
            guard !raw.uid.isEmpty, !raw.calendar_id.isEmpty else { continue }
            let event = Self.normalizeAllDay(raw, calendar: calendar)
            // An event spanning a query chunk boundary is returned twice.
            let key = "\(event.calendar_id)|\(event.uid)|\(event.occurrence_start.timeIntervalSince1970)"
            if seen.insert(key).inserted { events.append(event) }
        }
        events.sort { ($0.start, $0.calendar_id, $0.uid) < ($1.start, $1.calendar_id, $1.uid) }
        return CalendarBody(window: window, calendars: infos, events: events)
    }

    /// All-day events travel as local midnights: start at the first day's midnight, end at the
    /// midnight after the last day (exclusive), occurrence at its day's midnight. EventKit ends
    /// an all-day event at 23:59:59 of its last day; the server reads the day from the date part
    /// as sent, so the end is moved to the next midnight.
    public static func normalizeAllDay(_ e: CalendarEvent, calendar: Foundation.Calendar) -> CalendarEvent {
        guard e.all_day else { return e }
        var out = e
        let start = calendar.startOfDay(for: e.start)
        var end = calendar.startOfDay(for: e.end)
        if end != e.end { end = calendar.date(byAdding: .day, value: 1, to: end)! }
        if end <= start { end = calendar.date(byAdding: .day, value: 1, to: start)! }
        out.start = start
        out.end = end
        out.occurrence_start = calendar.startOfDay(for: e.occurrence_start)
        return out
    }
}
