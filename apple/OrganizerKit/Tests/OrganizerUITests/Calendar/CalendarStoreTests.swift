import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// The Calendar store against a stub server: windows load and are shared, hidden sources filter the
/// copies and persist, the agenda grows to a cap, and mirrored sources alert only when stale or failing.
@Suite("Calendar store")
@MainActor
struct CalendarStoreTests {
    static let today = LocalDate("2026-10-24")!
    /// A fixed instant for the stub's response envelope (the store reads the items, not these).
    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    let server = StubServer()
    let defaults = UserDefaults(suiteName: "calendar-tests-\(UUID().uuidString)")!

    init() {
        let items = [
            CalendarModelTests.timed("reminders:1", "Renew card", day: "2026-10-21", from: "09:00", to: "10:00", meta: ["reminder_id": .number(1)]),
            CalendarModelTests.allDay("apple:1", "Tax", from: "2026-10-10", to: "2026-10-11", source: "apple"),
            CalendarModelTests.allDay("holidays:1", "Columbus Day", from: "2026-10-12", to: "2026-10-13"),
        ]
        server.respond(.get, "/api/calendar", value: CalendarResponse(
            start: Self.epoch, end: Self.epoch.addingTimeInterval(86_400 * 30), items: items, errors: []))
        server.respond(.get, "/api/calendar/sources", value: [
            CalendarSourceOut(key: "reminders", label: "Reminders", color: "#F19A37", live: true),
            CalendarSourceOut(key: "apple", label: "Apple Calendar", color: "#8e8e93", live: false, freshness: Self.status("eventkit", .ok, hoursAgo: 0)),
            CalendarSourceOut(key: "holidays", label: "US holidays", color: "#a0782c", live: true),
        ])
        server.respond(.get, "/api/status/sources", value: [
            Self.status("eventkit", .stale, hoursAgo: 3),
            Self.status("health", .error, error: "Health Advisor not configured"),
            Self.status("github", .ok, hoursAgo: 0),
        ])
    }

    static func status(_ source: String, _ state: SourceStatusOut.State, hoursAgo: Double? = nil, error: String? = nil) -> SourceStatusOut {
        SourceStatusOut(
            source: source, label: source, state: state, staleAfterSeconds: 3600,
            lastSuccessAt: hoursAgo.map { Date().addingTimeInterval(-$0 * 3600) }, lastError: error)
    }

    func makeStore() -> CalendarStore {
        CalendarStore(client: server.client(), defaults: defaults, today: { Self.today })
    }

    // MARK: Windows

    @Test func agendaOpensOnTodaysChunkAndListsTodayFirst() {
        let store = makeStore()
        let windows = store.windows(for: .agenda)
        #expect(windows.count == 3)
        #expect(windows.first?.contains(Self.today) == true)
        #expect(store.neighbourWindows(for: .agenda).isEmpty)
    }

    @Test func theViewsReadOneWindowAndPrefetchTheNeighbours() {
        let store = makeStore()
        #expect(store.windows(for: .week) == [CalendarWindow.week(containing: Self.today)])
        let neighbours = store.neighbourWindows(for: .week)
        #expect(neighbours.map(\.start) == [LocalDate("2026-10-12"), LocalDate("2026-10-26")])
    }

    @Test func movingAMonthKeepsTheFirstOfTheMonth() {
        let store = makeStore()
        store.move(.month, by: 1)
        #expect(store.anchor == LocalDate("2026-11-01"))
        store.goToday()
        #expect(store.anchor == Self.today)
    }

    @Test func theAgendaGrowsEachWayToItsReachAndNoFurther() {
        let store = makeStore()
        let start = store.agendaChunks
        for _ in 0..<100 { store.extendAgenda(earlier: false) }
        #expect(store.agendaChunks.upperBound - start.upperBound == CalendarStore.agendaReach - 1)
        for _ in 0..<100 { store.extendAgenda(earlier: true) }
        #expect(store.agendaChunks.lowerBound - start.lowerBound == -(CalendarStore.agendaReach - 1))
    }

    // MARK: Loading

    @Test func aLoadedWindowShowsItsItems() async {
        let store = makeStore()
        let week = CalendarWindow.week(containing: Self.today)
        #expect(!store.status([week]).hasValue)

        await store.load([week])

        #expect(store.status([week]).hasValue)
        #expect(store.entries(in: [week]).map(\.id).sorted() == ["apple:1", "holidays:1", "reminders:1"])
        #expect(!server.requests(.get, "/api/calendar").isEmpty)
        #expect(server.requests(.get, "/api/calendar").first?.query?.contains("start=") == true)
    }

    @Test func overlappingCopiesShowEachItemOnce() async {
        let store = makeStore()
        let week = CalendarWindow.week(containing: Self.today)
        let month = CalendarWindow.month(containing: Self.today)
        await store.load([week, month])
        #expect(store.entries(in: [week, month]).count == 3)
    }

    @Test func hiddenSourcesFilterAndPersist() async {
        let store = makeStore()
        let week = CalendarWindow.week(containing: Self.today)
        await store.load([week])

        store.setShown("apple", false)

        #expect(store.entries(in: [week]).allSatisfy { $0.item.source != "apple" })
        #expect(defaults.stringArray(forKey: "calendar.hiddenSources") == ["apple"])
        let reopened = CalendarStore(client: server.client(), defaults: defaults, today: { Self.today })
        #expect(reopened.isShown("apple") == false)
        reopened.showAllSources()
        #expect(reopened.isShown("apple"))
    }

    @Test func providerErrorsSurfaceOncePerSource() async {
        server.respond(.get, "/api/calendar", value: CalendarResponse(
            start: Self.epoch, end: Self.epoch, items: [],
            errors: [ProviderError(source: "jobs.blocks", message: "database is locked")]))
        let store = makeStore()
        let week = CalendarWindow.week(containing: Self.today)
        await store.load([week])
        #expect(store.providerErrors(in: [week]).map(\.message) == ["database is locked"])
    }

    // MARK: Freshness

    @Test func theStripAlertsOnlyForStaleOrFailingSources() async {
        let store = makeStore()
        await store.prepare()
        #expect(store.freshnessAlerts.map(\.source) == ["eventkit"])
    }

    @Test func pullToRefreshFetchesTheWindowsAgain() async {
        let store = makeStore()
        let week = CalendarWindow.week(containing: Self.today)
        await store.load([week])
        let before = server.requests(.get, "/api/calendar").count
        await store.refreshAll([week])
        #expect(server.requests(.get, "/api/calendar").count > before)
    }
}
