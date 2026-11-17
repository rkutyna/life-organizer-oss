import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// The Calendar's pure parts: how feed items become days, the agenda and the timeline, the links an
/// item offers, and how a mirrored source reads. Items are built in this machine's zone, so the
/// expectations hold wherever the tests run.
@Suite("Calendar model")
struct CalendarModelTests {
    static let today = LocalDate("2026-10-24")!

    // MARK: Builders

    /// `time` on `day`, in this machine's zone, as the API sends instants (UTC, milliseconds).
    static func instant(_ day: String, _ time: String) -> String {
        let date = LocalTime(time)!.date(on: LocalDate(day)!, calendar: CalendarMath.calendar)
        return APIJSON.formatDateTime(date)
    }

    static func timed(
        _ id: String, _ title: String = "Item", day: String, from: String, to: String,
        source: String = "reminders", status: String? = nil, meta: [String: JSONValue] = [:]
    ) -> CalendarItem {
        CalendarItem(
            id: id, source: source, sourceLabel: "Label", title: title,
            start: instant(day, from), end: instant(day, to), allDay: false,
            color: "#3b6fd8", readOnly: false, meta: meta, status: status, detailUrl: nil
        )
    }

    static func allDay(_ id: String, _ title: String = "Holiday", from: String, to: String, source: String = "holidays") -> CalendarItem {
        CalendarItem(
            id: id, source: source, sourceLabel: "Label", title: title,
            start: from, end: to, allDay: true, color: "#a0782c", readOnly: true, meta: [:],
            status: nil, detailUrl: nil
        )
    }

    static func entry(_ item: CalendarItem) -> CalendarEntry {
        CalendarEntry(item)!
    }

    // MARK: Entries

    @Test func allDayItemsCoverTheirDaysAndNotTheEnd() throws {
        let item = Self.allDay("a", from: "2026-10-21", to: "2026-10-24")
        let entry = try #require(CalendarEntry(item))
        #expect(entry.firstDay == LocalDate("2026-10-21"))
        #expect(entry.lastDay == LocalDate("2026-10-23"))
        #expect(entry.touches(LocalDate("2026-10-23")!))
        #expect(!entry.touches(LocalDate("2026-10-24")!))
    }

    @Test func aTimedItemEndingAtMidnightDoesNotTouchThatDay() throws {
        // Ends at the next midnight, so it is a Saturday evening item only.
        let item = CalendarItem(
            id: "late", source: "reminders", sourceLabel: "L", title: "Late",
            start: Self.instant("2026-10-24", "22:00"), end: Self.instant("2026-10-25", "00:00"),
            allDay: false, color: "#000000", readOnly: false, meta: [:], status: nil, detailUrl: nil)
        let entry = try #require(CalendarEntry(item))
        #expect(entry.lastDay == LocalDate("2026-10-24"))
        #expect(!entry.touches(LocalDate("2026-10-25")!))
    }

    @Test func aTimedItemCrossingMidnightTouchesBothDays() throws {
        let item = CalendarItem(
            id: "n", source: "reminders", sourceLabel: "L", title: "Overnight",
            start: Self.instant("2026-10-24", "23:00"), end: Self.instant("2026-10-25", "01:00"),
            allDay: false, color: "#000000", readOnly: false, meta: [:], status: nil, detailUrl: nil)
        let entry = try #require(CalendarEntry(item))
        #expect(entry.firstDay == LocalDate("2026-10-24"))
        #expect(entry.lastDay == LocalDate("2026-10-25"))
    }

    @Test func unreadableTimesAreLeftOff() {
        let bad = CalendarItem(
            id: "x", source: "reminders", sourceLabel: "L", title: "Bad",
            start: "soon", end: "later", allDay: false, color: "#000000", readOnly: false, meta: [:],
            status: nil, detailUrl: nil)
        #expect(CalendarEntry(bad) == nil)
    }

    // MARK: Agenda

    @Test func agendaPutsAllDayFirstAndAlwaysShowsToday() {
        let window = CalendarWindow(start: LocalDate("2026-10-19")!, end: LocalDate("2026-10-28")!)
        let entries = [
            Self.entry(Self.timed("late", "Later", day: "2026-10-24", from: "09:00", to: "10:00")),
            Self.entry(Self.timed("early", "Early", day: "2026-10-24", from: "08:00", to: "08:30")),
            Self.entry(Self.allDay("all", "Trip", from: "2026-10-24", to: "2026-10-25")),
            Self.entry(Self.timed("next", "Next week", day: "2026-10-27", from: "08:00", to: "09:00")),
        ]
        let days = CalendarAgenda.days(entries, in: window, today: Self.today)

        #expect(days.map(\.day) == [LocalDate("2026-10-24")!, LocalDate("2026-10-27")!])
        #expect(days[0].entries.map(\.id) == ["all", "early", "late"])
    }

    @Test func agendaKeepsTodayWhenNothingIsOnIt() {
        let window = CalendarWindow.week(containing: Self.today)
        let days = CalendarAgenda.days([], in: window, today: Self.today)
        #expect(days.map(\.day) == [Self.today])
        #expect(days[0].entries.isEmpty)
    }

    @Test func agendaSpansAMultiDayItemOnEveryDay() {
        let window = CalendarWindow.week(containing: Self.today)
        let trip = Self.entry(Self.allDay("trip", "Conference", from: "2026-10-22", to: "2026-10-25"))
        let days = CalendarAgenda.days([trip], in: window, today: Self.today)
        #expect(days.map(\.day.string) == ["2026-10-22", "2026-10-23", "2026-10-24"])
    }

    // MARK: Timeline

    @Test func overlappingItemsShareTheWidth() {
        let a = Self.entry(Self.timed("a", day: "2026-10-24", from: "09:00", to: "10:00"))
        let b = Self.entry(Self.timed("b", day: "2026-10-24", from: "09:30", to: "11:00"))
        let c = Self.entry(Self.timed("c", day: "2026-10-24", from: "13:00", to: "14:00"))
        let blocks = DayTimeline.blocks([a, b, c], on: Self.today)

        let placedA = blocks.first { $0.entry.id == "a" }!
        let placedB = blocks.first { $0.entry.id == "b" }!
        let placedC = blocks.first { $0.entry.id == "c" }!
        #expect(placedA.columns == 2 && placedA.column == 0)
        #expect(placedB.columns == 2 && placedB.column == 1)
        #expect(placedC.columns == 1 && placedC.column == 0)
        #expect(placedA.startMinute == 540 && placedA.endMinute == 600)
    }

    @Test func aBlockOnTheNextDayStartsAtMidnight() {
        let night = Self.entry(CalendarItem(
            id: "n", source: "reminders", sourceLabel: "L", title: "Overnight",
            start: Self.instant("2026-10-24", "23:00"), end: Self.instant("2026-10-25", "01:00"),
            allDay: false, color: "#000000", readOnly: false, meta: [:], status: nil, detailUrl: nil))
        let tonight = DayTimeline.blocks([night], on: Self.today)
        let tomorrow = DayTimeline.blocks([night], on: LocalDate("2026-10-25")!)
        #expect(tonight.first?.startMinute == 1380 && tonight.first?.endMinute == 1440)
        #expect(tomorrow.first?.startMinute == 0 && tomorrow.first?.endMinute == 60)
    }

    @Test func allDayItemsStayOffTheTimeline() {
        let trip = Self.entry(Self.allDay("trip", from: "2026-10-24", to: "2026-10-25"))
        #expect(DayTimeline.blocks([trip], on: Self.today).isEmpty)
        #expect(DayTimeline.allDay([trip], on: Self.today).map(\.id) == ["trip"])
    }

    // MARK: Windows

    @Test func monthGridIsSixMondayWeeks() {
        let month = CalendarWindow.month(containing: Self.today)
        #expect(month.start == LocalDate("2026-09-28"))  // Monday before October 1
        #expect(month.days.count == 42)
        #expect(CalendarMath.weekdayIndex(of: month.start) == 0)
        #expect(month.contains(LocalDate("2026-10-31")!))
    }

    @Test func weeksStartOnMonday() {
        let week = CalendarWindow.week(containing: Self.today)
        #expect(week.start == LocalDate("2026-10-19"))
        #expect(week.days.count == 7)
    }

    @Test func agendaChunksAreTwoWeeksFromAFixedMonday() {
        let index = CalendarWindow.agendaChunkIndex(of: Self.today)
        let chunk = CalendarWindow.agendaChunk(index)
        #expect(CalendarMath.weekdayIndex(of: chunk.start) == 0)
        #expect(chunk.days.count == 14)
        #expect(chunk.contains(Self.today))
        #expect(CalendarWindow.agendaChunk(index + 1).start == chunk.end)
    }

    @Test func windowsOverlapOnlyWhenTheyShareADay() {
        let week = CalendarWindow.week(containing: Self.today)
        let next = CalendarWindow.week(containing: LocalDate("2026-10-26")!)
        #expect(week.overlaps(next) == false)
        #expect(week.overlaps(CalendarWindow.day(LocalDate("2026-10-25")!)))
    }

    // MARK: Summaries

    @Test func dayCountsAndDotsPerSource() {
        let window = CalendarWindow.week(containing: Self.today)
        let entries = [
            Self.entry(Self.timed("a", day: "2026-10-24", from: "09:00", to: "10:00")),
            Self.entry(Self.timed("b", day: "2026-10-24", from: "11:00", to: "12:00")),
            Self.entry(Self.allDay("c", from: "2026-10-24", to: "2026-10-25", source: "apple")),
        ]
        let summary = CalendarSummaries.byDay(entries, in: window)[Self.today]
        #expect(summary?.count == 3)
        #expect(summary?.dots.map(\.source) == ["reminders", "apple"])
        #expect(summary?.titles.count == 3)
    }

    @Test func densityTintsByCount() {
        #expect([0, 1, 2, 3, 4, 5, 6, 9].map(CalendarSummaries.densityLevel) == [0, 1, 2, 2, 3, 3, 4, 4])
    }

    // MARK: Links

    @Test func reminderItemsOpenTheReminderInReminders() throws {
        let item = CalendarItem(
            id: "reminders:9", source: "reminders", sourceLabel: "Reminders", title: "Renew card",
            start: "2026-10-24", end: "2026-10-25", allDay: true, color: "#F19A37", readOnly: false,
            meta: ["reminder_id": .number(9)], status: "open", detailUrl: "/reminders?reminder=9")
        let action = try #require(CalendarLinks.appAction(for: item, entry: nil))
        #expect(action.url.absoluteString == "lifeorganizer://reminders?reminder=9")
        #expect(DeepLink(action.url)?.module == .reminders)
    }

    @Test func jobItemsOpenTheirRecord() throws {
        let interview = CalendarItem(
            id: "jobs_interviews:1", source: "jobs_interviews", sourceLabel: "Interviews", title: "Acme screen",
            start: "2026-10-24T15:00:00Z", end: "2026-10-24T16:00:00Z", allDay: false, color: "#3b6fd8", readOnly: false,
            meta: [:], status: "interview", detailUrl: "/jobs/applications/1")
        let action = try #require(CalendarLinks.appAction(for: interview, entry: nil))
        #expect(action.url.absoluteString == "lifeorganizer://jobs/applications/1")
        #expect(CalendarLinks.jobsLink("/jobs/events?event=3").query == ["event": "3"])
        #expect(CalendarLinks.jobsLink("/jobs/events?event=3").path == ["events"])
        #expect(CalendarLinks.jobsLink("/elsewhere").path == [])
    }

    @Test func appleEventsOpenInCalendarAtTheirStart() throws {
        let item = Self.allDay("apple:1", "Tax", from: "2026-10-10", to: "2026-10-11", source: "apple")
        let action = try #require(CalendarLinks.appAction(for: item, entry: Self.entry(item)))
        #expect(action.url.scheme == "calshow")
    }

    @Test func mirroredItemsHaveNoModuleLink() {
        let event = Self.timed("calendar_ext:abc", "Dentist", day: "2026-10-12", from: "09:00", to: "10:00", source: "calendar_ext")
        #expect(CalendarLinks.appAction(for: event, entry: nil) == nil)
        let holiday = Self.allDay("holidays:2026-10-12", "Columbus Day", from: "2026-10-12", to: "2026-10-13")
        #expect(CalendarLinks.appAction(for: holiday, entry: nil) == nil)
    }

    @Test func webLinksAreAppPathsOrAbsoluteURLs() throws {
        let base = URL(string: "https://organizer.example.com")!
        let contact = CalendarItem(
            id: "jobs_due:contact-5", source: "jobs_due", sourceLabel: "Follow-ups", title: "Follow up",
            start: "2026-10-04", end: "2026-10-05", allDay: true, color: "#d97706", readOnly: false,
            meta: [:], status: "open", detailUrl: "/jobs/contacts/5")
        #expect(CalendarLinks.webURL(for: contact, base: base)?.absoluteString == "https://organizer.example.com/jobs/contacts/5")
        let holiday = CalendarItem(
            id: "holidays:2026-10-12", source: "holidays", sourceLabel: "Holidays", title: "Columbus Day",
            start: "2026-10-12", end: "2026-10-13", allDay: true, color: "#a0782c", readOnly: true,
            meta: [:], status: nil, detailUrl: "https://example.com/holidays")
        #expect(CalendarLinks.webURL(for: holiday, base: base)?.absoluteString == "https://example.com/holidays")
        let apple = Self.allDay("apple:1", from: "2026-10-10", to: "2026-10-11", source: "apple")
        #expect(CalendarLinks.webURL(for: apple, base: base) == nil)
    }

    // MARK: Details

    @Test func detailsSkipIdsAndNestedValues() {
        let item = Self.timed(
            "reminders:1", day: "2026-10-24", from: "09:00", to: "10:00",
            meta: ["task_id": .number(1), "priority": .number(3), "notes": .string(""),
                   "session": .object(["a": .number(1)]), "location": .null, "observed": .bool(false)])
        let rows = CalendarDetails.rows(for: item)
        #expect(rows.map(\.key) == ["observed", "priority"])
        #expect(rows.last?.label == "Priority")
        #expect(rows.last?.value == "3")
    }

    @Test func statusesReadAsWords() {
        #expect(CalendarLabels.status("open") == "Open")
        #expect(CalendarLabels.status("not_attended") == "Not attended")
        #expect(CalendarLabels.status("none") == nil)
        #expect(CalendarLabels.status(nil) == nil)
    }

    // MARK: Freshness

    static func status(_ source: String, _ state: SourceStatusOut.State, hoursAgo: Double? = nil, error: String? = nil) -> SourceStatusOut {
        SourceStatusOut(
            source: source, label: source.uppercased(), state: state, staleAfterSeconds: 3600,
            lastSuccessAt: hoursAgo.map { Date().addingTimeInterval(-$0 * 3600) },
            lastError: error)
    }

    @Test func aHealthySourceReadsAsOfItsAge() {
        let reading = CalendarFreshness.reading(Self.status("github", .ok, hoursAgo: 0))
        #expect(reading.tone == .ok)
        #expect(reading.text == "as of just now")
    }

    @Test func notConfiguredIsCalmNotAlarming() {
        let reading = CalendarFreshness.reading(Self.status("health", .error, error: "Health Advisor not configured"))
        #expect(reading.text == "not set up")
        #expect(reading.tone == .quiet)
        #expect(!CalendarFreshness.isNotConfigured(Self.status("github", .error, error: "rate limited")))
    }

    @Test func failingReadsWithTheLastSync() {
        let failing = CalendarFreshness.reading(Self.status("eventkit", .error, hoursAgo: 2, error: "helper away"))
        #expect(failing.tone == .error)
        #expect(failing.text.hasPrefix("failing · last synced"))
        #expect(CalendarFreshness.reading(Self.status("eventkit", .error, error: "helper away")).text == "failing")
    }

    @Test func onlyStaleAndFailingSourcesAlertInStripOrder() {
        let alerts = CalendarFreshness.alerts([
            Self.status("mail_2", .stale, hoursAgo: 30),
            Self.status("reminders", .ok, hoursAgo: 0),
            Self.status("custom_source", .stale, hoursAgo: 1),
            Self.status("calendar:1", .error, hoursAgo: 3, error: "401 from the CalDAV server"),
            Self.status("eventkit", .stale, hoursAgo: 3),
        ])
        #expect(alerts.map(\.source) == ["eventkit", "calendar:1", "mail_2", "custom_source"])
    }

    @Test func notSyncedYetIsQuiet() {
        let reading = CalendarFreshness.reading(Self.status("backup_onbox", .never))
        #expect(reading.tone == .quiet)
        #expect(reading.text == "not synced yet")
    }

    // MARK: Windows and time

    @Test func whenDescribesAllDayAndTimedItems() {
        let allDay = Self.entry(Self.allDay("a", from: "2026-10-24", to: "2026-10-25"))
        #expect(CalendarLabels.when(allDay).hasSuffix("All day"))
        let timed = Self.entry(Self.timed("t", day: "2026-10-24", from: "09:00", to: "10:00"))
        #expect(CalendarLabels.when(timed).contains("–"))
    }
}
