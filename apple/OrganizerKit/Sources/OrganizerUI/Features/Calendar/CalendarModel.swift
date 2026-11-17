import Foundation
import OrganizerAPI
import OrganizerCore
import SwiftUI

// The Calendar's pure parts: date arithmetic, the entries a feed item becomes, the agenda and
// timeline layout, colors and links. No views and no state, so the tests run them directly.

// MARK: - Arithmetic

/// The calendar's arithmetic: Gregorian in the device's time zone, weeks start on Monday (as the
/// web does). Display only: which days are weekends or holidays comes from the server's feed.
nonisolated enum CalendarMath {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        calendar.locale = .current
        return calendar
    }

    static var today: LocalDate { LocalDate.today(calendar: calendar) }

    /// Monday is 0 ... Sunday is 6.
    static func weekdayIndex(of day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> Int {
        let weekday = calendar.component(.weekday, from: day.date(in: calendar))  // Sunday is 1
        return (weekday + 5) % 7
    }

    static func monday(onOrBefore day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> LocalDate {
        day.adding(days: -weekdayIndex(of: day, calendar: calendar), calendar: calendar)
    }

    static func addingMonths(_ count: Int, to day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> LocalDate {
        LocalDate(calendar.date(byAdding: .month, value: count, to: day.date(in: calendar))!, calendar: calendar)
    }
}

/// A span of whole days: `start` through the day before `end`. Each view asks the store for the
/// windows it shows, and the store keeps one copy of the feed per window.
nonisolated struct CalendarWindow: Hashable, Sendable {
    let start: LocalDate
    /// Exclusive.
    let end: LocalDate

    init(start: LocalDate, end: LocalDate) {
        self.start = start
        self.end = end
    }

    func contains(_ day: LocalDate) -> Bool { start <= day && day < end }

    func overlaps(_ other: CalendarWindow) -> Bool { start < other.end && other.start < end }

    /// The days of the window, in order.
    var days: [LocalDate] {
        let calendar = CalendarMath.calendar
        var result: [LocalDate] = []
        var day = start
        while day < end {
            result.append(day)
            day = day.adding(days: 1, calendar: calendar)
        }
        return result
    }

    /// Agenda chunks: two weeks each, aligned to a fixed Monday, so a chunk has the same key from
    /// launch to launch.
    static let agendaChunkDays = 14
    private static let agendaEpoch = LocalDate(year: 2000, month: 1, day: 3)  // a Monday

    static func agendaChunkIndex(of day: LocalDate) -> Int {
        let days = agendaEpoch.days(until: day, calendar: CalendarMath.calendar)
        return Int((Double(days) / Double(agendaChunkDays)).rounded(.down))
    }

    static func agendaChunk(_ index: Int) -> CalendarWindow {
        let calendar = CalendarMath.calendar
        let start = agendaEpoch.adding(days: index * agendaChunkDays, calendar: calendar)
        return CalendarWindow(start: start, end: start.adding(days: agendaChunkDays, calendar: calendar))
    }

    static func day(_ day: LocalDate) -> CalendarWindow {
        CalendarWindow(start: day, end: day.adding(days: 1, calendar: CalendarMath.calendar))
    }

    static func week(containing day: LocalDate) -> CalendarWindow {
        let monday = CalendarMath.monday(onOrBefore: day)
        return CalendarWindow(start: monday, end: monday.adding(days: 7, calendar: CalendarMath.calendar))
    }

    /// Six Monday-first weeks, so every month fits the grid.
    static func month(containing day: LocalDate) -> CalendarWindow {
        let first = LocalDate(year: day.year, month: day.month, day: 1)
        let start = CalendarMath.monday(onOrBefore: first)
        return CalendarWindow(start: start, end: start.adding(days: 42, calendar: CalendarMath.calendar))
    }

    static func year(_ year: Int) -> CalendarWindow {
        CalendarWindow(start: LocalDate(year: year, month: 1, day: 1), end: LocalDate(year: year + 1, month: 1, day: 1))
    }
}

/// The views the screen offers. The stored choice is per device; the default depends on width.
nonisolated enum CalendarViewMode: String, CaseIterable, Identifiable, Sendable {
    case agenda, day, week, month, year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agenda: "Agenda"
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        }
    }
}

// MARK: - Entries

/// One feed item with its times read: a timed item has instants, an all-day item has the days
/// it covers. Reading the feed once here keeps every view's day math in one place.
nonisolated struct CalendarEntry: Identifiable, Hashable, Sendable {
    let item: CalendarItem
    /// Timed items only.
    let start: Date?
    let end: Date?
    /// The first day touched, and the last day touched (inclusive).
    let firstDay: LocalDate
    let lastDay: LocalDate

    var id: String { item.id }

    /// nil when the item's times do not parse; such an item is left off the calendar.
    init?(_ item: CalendarItem, calendar: Calendar = CalendarMath.calendar) {
        self.item = item
        if item.allDay {
            guard let first = LocalDate(item.start) else { return nil }
            // The feed's end is exclusive: a one-day item on the 26th ends on the 27th.
            let stop = LocalDate(item.end) ?? first.adding(days: 1, calendar: calendar)
            start = nil
            end = nil
            firstDay = first
            lastDay = max(first, stop.adding(days: -1, calendar: calendar))
        } else {
            guard let from = APIJSON.parseDateTime(item.start) else { return nil }
            let until = max(from, APIJSON.parseDateTime(item.end) ?? from)
            start = from
            end = until
            firstDay = LocalDate(from, calendar: calendar)
            var last = LocalDate(until, calendar: calendar)
            // An end at exactly midnight does not touch the day it ends on.
            if until > from, calendar.startOfDay(for: until) == until {
                last = last.adding(days: -1, calendar: calendar)
            }
            lastDay = max(firstDay, last)
        }
    }

    func touches(_ day: LocalDate) -> Bool { firstDay <= day && day <= lastDay }

    /// The days of the entry inside `window`, in order.
    func days(in window: CalendarWindow, calendar: Calendar = CalendarMath.calendar) -> [LocalDate] {
        let last = min(lastDay, window.end.adding(days: -1, calendar: calendar))
        var result: [LocalDate] = []
        var day = max(firstDay, window.start)
        while day <= last {
            result.append(day)
            day = day.adding(days: 1, calendar: calendar)
        }
        return result
    }

    /// Within a day: all-day items first, then by start, then by title.
    static func precedes(_ a: CalendarEntry, _ b: CalendarEntry) -> Bool {
        if a.item.allDay != b.item.allDay { return a.item.allDay }
        if let sa = a.start, let sb = b.start, sa != sb { return sa < sb }
        return a.item.title.localizedStandardCompare(b.item.title) == .orderedAscending
    }
}

// MARK: - Agenda

/// One day of the agenda.
nonisolated struct AgendaDay: Identifiable, Sendable {
    let day: LocalDate
    let entries: [CalendarEntry]

    var id: String { day.string }
}

nonisolated enum CalendarAgenda {
    /// The days of `window` that have something on them, in order. Today is always there, empty
    /// or not, so the agenda opens on it.
    static func days(_ entries: [CalendarEntry], in window: CalendarWindow, today: LocalDate) -> [AgendaDay] {
        var byDay: [LocalDate: [CalendarEntry]] = [:]
        for entry in entries {
            for day in entry.days(in: window) {
                byDay[day, default: []].append(entry)
            }
        }
        if window.contains(today), byDay[today] == nil {
            byDay[today] = []
        }
        return byDay.keys.sorted().map { day in
            AgendaDay(day: day, entries: (byDay[day] ?? []).sorted(by: CalendarEntry.precedes))
        }
    }
}

// MARK: - Timeline

/// A timed item placed on one day's timeline, in minutes since local midnight.
nonisolated struct TimelineBlock: Identifiable, Sendable {
    let entry: CalendarEntry
    let day: LocalDate
    let startMinute: Double
    let endMinute: Double
    /// Its side-by-side slot: `column` of `columns` among the items it overlaps.
    let column: Int
    let columns: Int

    var id: String { "\(entry.id)@\(day.string)" }
}

nonisolated enum DayTimeline {
    static let minutesPerDay: Double = 1440
    /// The shortest span a block is laid out at, so a zero-length item still shows.
    static let minimumMinutes: Double = 30

    /// The all-day items touching `day`, in agenda order.
    static func allDay(_ entries: [CalendarEntry], on day: LocalDate) -> [CalendarEntry] {
        entries.filter { $0.item.allDay && $0.touches(day) }.sorted(by: CalendarEntry.precedes)
    }

    /// The timed items touching `day`, placed side by side where they overlap. Clusters of
    /// overlapping items share their width; a cluster's items take the first free column.
    static func blocks(_ entries: [CalendarEntry], on day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> [TimelineBlock] {
        let dayStart = day.date(in: calendar)
        let nextStart = day.adding(days: 1, calendar: calendar).date(in: calendar)

        struct Span {
            let entry: CalendarEntry
            let start: Double
            let end: Double
        }
        let spans: [Span] = entries.compactMap { entry in
            guard !entry.item.allDay, entry.touches(day), let start = entry.start, let end = entry.end else {
                return nil
            }
            let from = start <= dayStart ? 0 : minute(of: start, calendar: calendar)
            let until = end >= nextStart ? minutesPerDay : minute(of: end, calendar: calendar)
            return Span(entry: entry, start: from, end: min(minutesPerDay, max(until, from + minimumMinutes)))
        }

        let sorted = spans.sorted { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }
        var blocks: [TimelineBlock] = []
        var cluster: [(span: Span, column: Int)] = []
        var columnEnds: [Double] = []
        var clusterEnd = 0.0

        func flushCluster() {
            for placed in cluster {
                blocks.append(TimelineBlock(
                    entry: placed.span.entry, day: day, startMinute: placed.span.start,
                    endMinute: placed.span.end, column: placed.column, columns: columnEnds.count))
            }
            cluster = []
            columnEnds = []
        }

        for span in sorted {
            if !cluster.isEmpty, span.start >= clusterEnd {
                flushCluster()
                clusterEnd = 0
            }
            let column = columnEnds.firstIndex { $0 <= span.start } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(span.end)
            } else {
                columnEnds[column] = span.end
            }
            cluster.append((span, column))
            clusterEnd = max(clusterEnd, span.end)
        }
        flushCluster()
        return blocks
    }

    /// Wall-clock minutes since midnight. Wall-clock, so a 23- or 25-hour day still lines up with
    /// the 24 hour rows.
    static func minute(of instant: Date, calendar: Calendar = CalendarMath.calendar) -> Double {
        let parts = calendar.dateComponents([.hour, .minute], from: instant)
        return Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }
}

// MARK: - Month and year

/// One source's dot on a day.
nonisolated struct CalendarDot: Identifiable, Hashable, Sendable {
    let source: String
    let color: Color

    var id: String { source }
}

/// What a day holds, for the month and year grids.
nonisolated struct DaySummary: Sendable {
    var count = 0
    /// One dot per source, in first-seen order.
    var dots: [CalendarDot] = []
    var titles: [String] = []
}

nonisolated enum CalendarSummaries {
    static func byDay(_ entries: [CalendarEntry], in window: CalendarWindow) -> [LocalDate: DaySummary] {
        var result: [LocalDate: DaySummary] = [:]
        for entry in entries {
            for day in entry.days(in: window) {
                var summary = result[day, default: DaySummary()]
                summary.count += 1
                if !summary.dots.contains(where: { $0.source == entry.item.source }) {
                    summary.dots.append(CalendarDot(source: entry.item.source, color: Palette.item(source: entry.item.source, color: entry.item.color)))
                }
                if summary.titles.count < 6 {
                    summary.titles.append(entry.item.title)
                }
                result[day] = summary
            }
        }
        return result
    }

    /// Tint strength by number of items, as the web's year view: 0, 1, 2-3, 4-5, 6+.
    static func densityLevel(_ count: Int) -> Int {
        switch count {
        case 0: 0
        case 1: 1
        case 2...3: 2
        case 4...5: 3
        default: 4
        }
    }
}

// MARK: - Labels

/// Words for the periods and items the screen shows.
nonisolated enum CalendarLabels {
    /// "Thursday, October 24", with the year when it is not this year.
    static func day(_ day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return day.date(in: calendar).formatted(style) + yearSuffix(day)
    }

    /// "Thu, Oct 24", for a line inside a list.
    static func shortDay(_ day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return day.date(in: calendar).formatted(style)
    }

    /// "Oct 19 – 25" within a month, "Oct 26 – Nov 1" across two.
    static func week(_ window: CalendarWindow, calendar: Calendar = CalendarMath.calendar) -> String {
        let last = window.end.adding(days: -1, calendar: calendar)
        let monthDay = Date.FormatStyle.dateTime.month(.abbreviated).day()
        let dayOnly = Date.FormatStyle.dateTime.day()
        let first = window.start.date(in: calendar).formatted(monthDay)
        let end = last.month == window.start.month
            ? last.date(in: calendar).formatted(dayOnly)
            : last.date(in: calendar).formatted(monthDay)
        return "\(first) – \(end)" + yearSuffix(last)
    }

    /// "October 2026".
    static func month(_ day: LocalDate, calendar: Calendar = CalendarMath.calendar) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .current
        return day.date(in: calendar).formatted(style)
    }

    static func year(_ day: LocalDate) -> String { String(day.year) }

    /// "9:00 AM".
    static func time(_ instant: Date) -> String {
        instant.formatted(date: .omitted, time: .shortened)
    }

    /// "Thu, Oct 24 · 9:00 – 10:00 AM", "Thu, Oct 24 · All day", "Oct 21 – 23 · All day".
    static func when(_ entry: CalendarEntry, calendar: Calendar = CalendarMath.calendar) -> String {
        if let start = entry.start, let end = entry.end {
            let from = time(start)
            if entry.firstDay == entry.lastDay {
                return "\(shortDay(entry.firstDay, calendar: calendar)) · \(from) – \(time(end))"
            }
            return "\(shortDay(entry.firstDay, calendar: calendar)) \(from) – \(shortDay(entry.lastDay, calendar: calendar)) \(time(end))"
        }
        if entry.firstDay == entry.lastDay {
            return "\(shortDay(entry.firstDay, calendar: calendar)) · All day"
        }
        let last = entry.lastDay
        return "\(shortDay(entry.firstDay, calendar: calendar)) – \(shortDay(last, calendar: calendar)) · All day"
    }

    /// "Done" for "done"; "open" reads "Open". Nil when the source has no status to show.
    static func status(_ status: String?) -> String? {
        guard let status, !status.isEmpty, status.lowercased() != "none" else { return nil }
        let words = status.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// ", 2027" for a year other than this one, else nothing.
    private static func yearSuffix(_ day: LocalDate) -> String {
        day.year == CalendarMath.today.year ? "" : ", \(day.year)"
    }
}

// MARK: - Details

/// One line of an item's details: the scalar meta the server sent, labelled.
nonisolated struct CalendarDetail: Identifiable, Sendable {
    let key: String
    let label: String
    let value: String

    var id: String { key }
}

nonisolated enum CalendarDetails {
    /// The scalar meta, sorted by key. Internal ids (`*_id`) and empty or nested values are left
    /// out; the detail sheet is for what a person reads.
    static func rows(for item: CalendarItem) -> [CalendarDetail] {
        item.meta.compactMap { key, value -> CalendarDetail? in
            guard !key.hasSuffix("_id") else { return nil }
            switch value {
            case .string(let text) where !text.isEmpty:
                break
            case .bool, .number:
                break
            default:
                return nil
            }
            let words = key.replacingOccurrences(of: "_", with: " ")
            return CalendarDetail(key: key, label: words.prefix(1).uppercased() + words.dropFirst(), value: value.displayText)
        }
        .sorted { $0.key < $1.key }
    }
}

// MARK: - Freshness

/// How a mirrored source reads (web SourceFreshness). "not set up" and "not synced yet" are states,
/// not alarms, so the strip shows only the stale and the failing.
nonisolated enum CalendarFreshness {
    enum Tone: Sendable {
        case ok, stale, error, quiet
    }

    struct Reading: Sendable {
        let text: String
        let tone: Tone
    }

    /// The server's "not configured" error: a source the person never set up.
    static func isNotConfigured(_ status: SourceStatusOut) -> Bool {
        status.state == .error && (status.lastError?.contains("not configured") ?? false)
    }

    static func reading(_ status: SourceStatusOut, now: Date = .now) -> Reading {
        if isNotConfigured(status) {
            return Reading(text: "not set up", tone: .quiet)
        }
        switch status.state {
        case .ok:
            return Reading(text: "as of \(age(status.lastSuccessAt, now: now))", tone: .ok)
        case .stale:
            return Reading(text: "stale · as of \(age(status.lastSuccessAt, now: now))", tone: .stale)
        case .error:
            if let last = status.lastSuccessAt {
                return Reading(text: "failing · last synced \(age(last, now: now))", tone: .error)
            }
            return Reading(text: "failing", tone: .error)
        default:
            return Reading(text: "not synced yet", tone: .quiet)
        }
    }

    /// The sources worth a warning, in the strip's order: calendars first, then the other mirrors,
    /// then the backup. A source the server adds later goes last, in the server's order.
    static func alerts(_ statuses: [SourceStatusOut], now: Date = .now) -> [SourceStatusOut] {
        let order = ["eventkit", "calendar", "reminders", "mail"]
        func rank(_ source: String) -> Int {
            order.firstIndex { source == $0 || source.hasPrefix($0 + ":") || source.hasPrefix($0 + "_") } ?? order.count
        }
        let flagged = statuses.filter { status in
            let tone = reading(status, now: now).tone
            return tone == .stale || tone == .error
        }
        return flagged.enumerated()
            .sorted { (rank($0.element.source), $0.offset) < (rank($1.element.source), $1.offset) }
            .map(\.element)
    }

    /// "12 minutes ago", as the "as of" badge says it (`Freshness.age`), or a word for no time.
    private static func age(_ date: Date?, now: Date) -> String {
        date.map { Freshness.age(of: $0, now: now) } ?? "at an unknown time"
    }
}

// MARK: - Links

/// Where an item's links go : owned items open their module by deep link, an Apple
/// event opens in Calendar, and every item can open its page on the web.
nonisolated enum CalendarLinks {
    struct Action: Equatable, Sendable {
        let title: String
        let systemImage: String
        let url: URL
    }

    /// Owned items open their module: a reminder by `lifeorganizer://reminders?reminder=<id>`, a
    /// job item by its record (`jobsLink`). An Apple event opens Calendar at its start.
    static func appAction(for item: CalendarItem, entry: CalendarEntry?) -> Action? {
        switch item.source {
        case "reminders":
            guard let id = numericID(item, key: "reminder_id") else { return nil }
            return deepLink(DeepLink(module: .reminders, query: ["reminder": id]), title: "Open in Reminders", systemImage: "checklist")
        case "apple":
            // An all-day event has no instant: Calendar opens on its first day.
            guard let entry else { return nil }
            let instant = entry.start ?? entry.firstDay.date(in: CalendarMath.calendar)
            guard let url = URL(string: "calshow:\(Int(instant.timeIntervalSinceReferenceDate))") else { return nil }
            return Action(title: "Open in Calendar", systemImage: "calendar", url: url)
        case let source where source.hasPrefix("jobs_") || source.hasPrefix("jobs."):
            return deepLink(jobsLink(item.detailUrl), title: "Open in Jobs", systemImage: "briefcase")
        default:
            return nil
        }
    }

    /// The item's page on the web: an absolute link as sent, or an app path on the server's web app.
    static func webURL(for item: CalendarItem, base: URL) -> URL? {
        guard let detail = item.detailUrl, !detail.isEmpty else { return nil }
        if detail.hasPrefix("http"), let url = URL(string: detail) { return url }
        return ServerConfig.webURL(path: detail, base: base)
    }

    /// A job item opens its record, from the server's `detail_url`: `/jobs/applications/12` is
    /// `lifeorganizer://jobs/applications/12` (contacts alike), and `/jobs/events?event=3` keeps
    /// its query. Anything else opens Jobs as it was.
    static func jobsLink(_ detailURL: String?) -> DeepLink {
        guard let detailURL, let components = URLComponents(string: detailURL) else { return DeepLink(module: .jobs) }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.first == "jobs" else { return DeepLink(module: .jobs) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return DeepLink(module: .jobs, path: Array(parts.dropFirst()), query: query)
    }

    private static func deepLink(_ link: DeepLink, title: String, systemImage: String) -> Action? {
        guard let url = link.url else { return nil }
        return Action(title: title, systemImage: systemImage, url: url)
    }

    /// The item's id in its meta (`reminder_id`), else the number after the colon in `"reminders:3"`.
    private static func numericID(_ item: CalendarItem, key: String) -> String? {
        if let number = item.meta[key]?.intValue { return String(number) }
        guard let tail = item.id.split(separator: ":").last, Int(tail) != nil else { return nil }
        return String(tail)
    }
}
