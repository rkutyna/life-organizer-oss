import Foundation
import Observation
import OrganizerAPI
import OrganizerCore

/// The Calendar screen's state: one copy of the feed per window of days, the sources, freshness,
/// the day the screen centres on, and which sources are shown. Built like every store: one `Resource` per read.
///
/// - Each window is a `Resource`: it starts from the cached copy, refreshes, and keeps the last good one.
/// - The agenda is a run of two-week chunks that grows as you scroll. The other views read one
///   window and prefetch the windows either side of it.
/// - Hidden sources are filtered here, on the copies, so switching one costs no request.
/// - Nothing here writes. Items are read-only in the calendar; owned ones open in their module.
@MainActor
@Observable
final class CalendarStore {
    /// How far the agenda may grow each way from today: 26 chunks, about a year.
    static let agendaReach = 26

    let sources: Resource<[CalendarSourceOut]>
    let freshness: Resource<[SourceStatusOut]>

    /// The day the day, week, month and year views centre on.
    var anchor: LocalDate

    /// The agenda's chunks shown, by index (see `CalendarWindow.agendaChunk`). Only grows.
    private(set) var agendaChunks: ClosedRange<Int>

    /// Source keys switched off in the Calendars sheet, per device.
    var hiddenSources: Set<String> {
        didSet { defaults.set(Array(hiddenSources).sorted(), forKey: Keys.hiddenSources) }
    }

    /// One read per window, created the first time the window is loaded.
    private(set) var reads: [CalendarWindow: Resource<CalendarResponse>] = [:]

    @ObservationIgnored let client: OrganizerClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let today: () -> LocalDate

    private enum Keys {
        static let hiddenSources = "calendar.hiddenSources"
    }

    init(
        client: OrganizerClient,
        defaults: UserDefaults = .standard,
        today: @escaping () -> LocalDate = { CalendarMath.today }
    ) {
        self.client = client
        self.defaults = defaults
        self.today = today
        sources = Resource(API.Calendar.listSources(), client: client)
        freshness = Resource(API.Status.listSourceStatus(), client: client)
        let now = today()
        anchor = now
        let chunk = CalendarWindow.agendaChunkIndex(of: now)
        agendaChunks = (chunk - 1)...(chunk + 1)
        hiddenSources = Set(defaults.stringArray(forKey: Keys.hiddenSources) ?? [])
    }

    // MARK: - Windows

    /// The windows a view reads: the agenda's chunks, today's first; otherwise the one around the anchor.
    func windows(for view: CalendarViewMode) -> [CalendarWindow] {
        guard view == .agenda else { return [window(view, at: anchor)] }
        let center = CalendarWindow.agendaChunkIndex(of: today())
        return agendaChunks.sorted { abs($0 - center) < abs($1 - center) }.map(CalendarWindow.agendaChunk)
    }

    /// The windows either side of the anchor's, prefetched so moving to them is instant. The agenda
    /// grows from its own edges instead.
    func neighbourWindows(for view: CalendarViewMode) -> [CalendarWindow] {
        guard view != .agenda else { return [] }
        return [-1, 1].map { window(view, at: stepped(view, by: $0)) }
    }

    /// The agenda's whole span, from its first chunk to its last.
    var agendaSpan: CalendarWindow {
        CalendarWindow(
            start: CalendarWindow.agendaChunk(agendaChunks.lowerBound).start,
            end: CalendarWindow.agendaChunk(agendaChunks.upperBound).end
        )
    }

    private func window(_ view: CalendarViewMode, at day: LocalDate) -> CalendarWindow {
        switch view {
        case .agenda, .day: .day(day)
        case .week: .week(containing: day)
        case .month: .month(containing: day)
        case .year: .year(day.year)
        }
    }

    /// The anchor one step of `view` away: a day, a week, a month or a year.
    private func stepped(_ view: CalendarViewMode, by count: Int) -> LocalDate {
        switch view {
        case .agenda, .day:
            anchor.adding(days: count, calendar: CalendarMath.calendar)
        case .week:
            anchor.adding(days: 7 * count, calendar: CalendarMath.calendar)
        case .month:
            firstOfMonth(CalendarMath.addingMonths(count, to: anchor))
        case .year:
            firstOfMonth(CalendarMath.addingMonths(12 * count, to: anchor))
        }
    }

    private func firstOfMonth(_ day: LocalDate) -> LocalDate {
        LocalDate(year: day.year, month: day.month, day: 1)
    }

    // MARK: - Navigation

    func goToday() {
        anchor = today()
    }

    func show(_ day: LocalDate) {
        anchor = day
    }

    func move(_ view: CalendarViewMode, by count: Int) {
        anchor = stepped(view, by: count)
    }

    /// The agenda reached its top or its bottom: two more weeks that way, up to `agendaReach` from today.
    func extendAgenda(earlier: Bool) {
        let center = CalendarWindow.agendaChunkIndex(of: today())
        if earlier {
            guard agendaChunks.lowerBound > center - Self.agendaReach else { return }
            agendaChunks = (agendaChunks.lowerBound - 1)...agendaChunks.upperBound
        } else {
            guard agendaChunks.upperBound < center + Self.agendaReach else { return }
            agendaChunks = agendaChunks.lowerBound...(agendaChunks.upperBound + 1)
        }
    }

    // MARK: - Loading

    /// Runs when the screen opens: today's chunk is in the agenda (the app may have been open across
    /// midnight), and the sources and freshness load.
    func prepare() async {
        let center = CalendarWindow.agendaChunkIndex(of: today())
        if !agendaChunks.contains(center) {
            agendaChunks = min(center - 1, agendaChunks.lowerBound)...max(center + 1, agendaChunks.upperBound)
        }
        async let sources: Void = self.sources.refreshIfStale(maxAge: 300)
        async let freshness: Void = self.freshness.refreshIfStale(maxAge: 60)
        _ = await (sources, freshness)
    }

    /// Fetches the windows whose copies are missing or older than two minutes, in parallel.
    func load(_ windows: [CalendarWindow]) async {
        let reads = windows.map(read)
        await withTaskGroup(of: Void.self) { group in
            for read in reads {
                group.addTask { await read.refreshIfStale(maxAge: 120) }
            }
        }
    }

    /// Pull to refresh: the windows on screen, and the sources and freshness, fetched now.
    func refreshAll(_ windows: [CalendarWindow]) async {
        let reads = windows.map(read)
        async let sources: Void = self.sources.refresh()
        async let freshness: Void = self.freshness.refresh()
        async let items: Void = refreshEach(reads)
        _ = await (sources, freshness, items)
    }

    private func refreshEach(_ reads: [Resource<CalendarResponse>]) async {
        await withTaskGroup(of: Void.self) { group in
            for read in reads {
                group.addTask { await read.refresh() }
            }
        }
    }

    /// The read for a window, created (with its cached copy, if any) the first time it is needed.
    private func read(_ window: CalendarWindow) -> Resource<CalendarResponse> {
        if let existing = reads[window] { return existing }
        let calendar = CalendarMath.calendar
        let created = Resource(
            API.Calendar.getCalendar(
                start: window.start.date(in: calendar),
                end: window.end.date(in: calendar)
            ),
            client: client
        )
        reads[window] = created
        return created
    }

    // MARK: - Reads

    /// What the windows show: every loaded copy that overlaps them, minus hidden sources, each item once.
    func entries(in windows: [CalendarWindow]) -> [CalendarEntry] {
        var seen = Set<String>()
        var entries: [CalendarEntry] = []
        for (window, read) in reads where windows.contains(where: { $0.overlaps(window) }) {
            for item in read.value?.items ?? [] where isShown(item.source) && !seen.contains(item.id) {
                guard let entry = CalendarEntry(item) else { continue }
                seen.insert(item.id)
                entries.append(entry)
            }
        }
        return entries.sorted { a, b in
            a.firstDay != b.firstDay ? a.firstDay < b.firstDay : CalendarEntry.precedes(a, b)
        }
    }

    /// The status of the windows on screen. The first is the one the screen needs; the rest only add to it.
    func status(_ windows: [CalendarWindow]) -> LoadStatus {
        let statuses = windows.map { reads[$0]?.state.status ?? LoadStatus(hasValue: false) }
        guard let first = statuses.first else { return LoadStatus(hasValue: false) }
        return LoadStatus(primary: first, secondary: Array(statuses.dropFirst()))
    }

    /// Errors the server reported for the windows on screen (a source that failed to answer), once per source.
    func providerErrors(in windows: [CalendarWindow]) -> [ProviderError] {
        var seen = Set<String>()
        var errors: [ProviderError] = []
        for (window, read) in reads where windows.contains(where: { $0.overlaps(window) }) {
            for error in read.value?.errors ?? [] where seen.insert(error.source).inserted {
                errors.append(error)
            }
        }
        return errors.sorted { $0.source < $1.source }
    }

    /// The mirrored sources that are stale or failing. Empty means the strip is hidden.
    var freshnessAlerts: [SourceStatusOut] {
        CalendarFreshness.alerts(freshness.value ?? [])
    }

    // MARK: - Sources

    func isShown(_ source: String) -> Bool {
        !hiddenSources.contains(source)
    }

    func setShown(_ source: String, _ shown: Bool) {
        if shown {
            hiddenSources.remove(source)
        } else {
            hiddenSources.insert(source)
        }
    }

    func showAllSources() {
        hiddenSources = []
    }
}
