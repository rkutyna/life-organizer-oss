import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The Calendar module's root screen (the registry names this type; keep the name). One calendar
/// over every source, in an agenda, a day, a week, a month or a year.
struct CalendarScreen: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        CalendarView(store: app.store { CalendarStore(client: $0) })
    }
}

/// Handles `lifeorganizer://calendar?view=week&date=2026-10-24`: `date` opens that day (the day view
/// when the agenda was showing), `view` picks the view.
struct CalendarView: View {
    @Bindable var store: CalendarStore
    @Environment(AppEnvironment.self) private var app
    /// The view the person picked. Empty until they pick one: the week.
    @AppStorage("calendar.view") private var storedView = ""
    /// The agenda's top day: the list scrolls to it, and its month is the title.
    @State private var agendaTop: String?
    @State private var opened: CalendarEntry?
    @State private var showingCalendars = false

    private var view: CalendarViewMode {
        CalendarViewMode(rawValue: storedView) ?? .week
    }

    private var viewChoice: Binding<CalendarViewMode> {
        Binding(
            get: { view },
            set: { next in
                storedView = next.rawValue
                if next == .agenda { agendaTop = CalendarMath.today.string }
            }
        )
    }

    /// The windows on screen, and the ones prefetched beside them.
    private var loadWindows: [CalendarWindow] {
        store.windows(for: view) + store.neighbourWindows(for: view)
    }

    private var shownWindows: [CalendarWindow] {
        store.windows(for: view)
    }

    var body: some View {
        ModuleNavigationStack {
            VStack(spacing: 0) {
                header
                LoadingScaffold(status: scaffoldStatus, refresh: { await store.refreshAll(shownWindows) }) {
                    content
                }
            }
            .navigationTitle("Calendar")
            .toolbar { toolbar }
            .sheet(item: $opened) { entry in
                CalendarItemSheet(entry: entry)
            }
            .sheet(isPresented: $showingCalendars) {
                CalendarSourcesSheet(store: store)
            }
            .task { await store.prepare() }
            .task(id: loadWindows) { await store.load(loadWindows) }
            .task { await pollFreshness() }
            .task(id: app.deepLink(for: .calendar)?.id) { apply(app.deepLink(for: .calendar)) }
            .onAppear {
                if agendaTop == nil { agendaTop = CalendarMath.today.string }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch view {
        case .agenda:
            CalendarAgendaView(
                days: CalendarAgenda.days(store.entries(in: shownWindows), in: store.agendaSpan, today: CalendarMath.today),
                today: CalendarMath.today,
                top: $agendaTop,
                canExtendEarlier: store.agendaChunks.lowerBound > CalendarWindow.agendaChunkIndex(of: CalendarMath.today) - CalendarStore.agendaReach,
                canExtendLater: store.agendaChunks.upperBound < CalendarWindow.agendaChunkIndex(of: CalendarMath.today) + CalendarStore.agendaReach,
                onExtend: { earlier in store.extendAgenda(earlier: earlier) },
                onOpen: { opened = $0 }
            )
        case .day:
            CalendarTimelineView(
                days: [store.anchor],
                entries: store.entries(in: shownWindows),
                today: CalendarMath.today,
                onOpen: { opened = $0 },
                onPickDay: nil
            )
        case .week:
            CalendarTimelineView(
                days: CalendarWindow.week(containing: store.anchor).days,
                entries: store.entries(in: shownWindows),
                today: CalendarMath.today,
                onOpen: { opened = $0 },
                onPickDay: pickDay
            )
        case .month:
            CalendarMonthView(
                month: store.anchor,
                entries: store.entries(in: shownWindows),
                today: CalendarMath.today,
                onPickDay: pickDay
            )
        case .year:
            CalendarYearView(
                year: store.anchor.year,
                entries: store.entries(in: shownWindows),
                today: CalendarMath.today,
                onPickDay: pickDay,
                onPickMonth: { month in
                    store.show(month)
                    storedView = CalendarViewMode.month.rawValue
                }
            )
        }
    }

    /// The windows' status, except that the day and week timelines draw their (empty) grid while
    /// the first read runs, instead of the spinner. On iPhone, a week that replaced the spinner
    /// could open a header's height too low (10/24); a week that is there from the start never
    /// did. A first read that fails still shows the error.
    private var scaffoldStatus: LoadStatus {
        var status = store.status(shownWindows)
        if view == .day || view == .week, !status.hasValue, status.error == nil {
            status.hasValue = true
        }
        return status
    }

    /// A day picked in the month, year or week grid opens that day.
    private func pickDay(_ day: LocalDate) {
        store.show(day)
        storedView = CalendarViewMode.day.rawValue
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Picker("View", selection: viewChoice) {
                ForEach(CalendarViewMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("calendar.view")

            HStack(spacing: 10) {
                if view != .agenda {
                    Button {
                        store.move(view, by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous")
                }
                Text(periodTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("calendar.period")
                if view != .agenda {
                    Button {
                        store.move(view, by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next")
                }
                Spacer(minLength: 0)
                Button("Today") {
                    store.goToday()
                    agendaTop = CalendarMath.today.string
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("calendar.today")
            }
            .buttonStyle(.borderless)

            CalendarNoticeStrip(notices: notices)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var periodTitle: String {
        switch view {
        case .agenda:
            let top = agendaTop.flatMap(LocalDate.init) ?? CalendarMath.today
            return CalendarLabels.month(top)
        case .day:
            return CalendarLabels.day(store.anchor)
        case .week:
            return CalendarLabels.week(CalendarWindow.week(containing: store.anchor))
        case .month:
            return CalendarLabels.month(store.anchor)
        case .year:
            return CalendarLabels.year(store.anchor)
        }
    }

    /// Stale or failing sources, and the server's own errors for the windows on screen. Empty when
    /// all is well, and then the strip is hidden.
    private var notices: [CalendarNotice] {
        let stale = CalendarFreshness.alerts(store.freshness.value ?? []).map { status in
            let reading = CalendarFreshness.reading(status)
            return CalendarNotice(
                id: "source:\(status.source)",
                text: "\(status.label) · \(reading.text)",
                isError: reading.tone == .error
            )
        }
        let labels = Dictionary(uniqueKeysWithValues: (store.sources.value ?? []).map { ($0.key, $0.label) })
        let failed = store.providerErrors(in: loadWindows).map { error in
            CalendarNotice(
                id: "feed:\(error.source)",
                text: "\(labels[error.source] ?? error.source): \(error.message)",
                isError: true
            )
        }
        return stale + failed
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingCalendars = true
            } label: {
                Label("Calendars", systemImage: "square.3.layers.3d")
            }
            .accessibilityIdentifier("calendar.calendars")
            .accessibilityValue(hiddenCountText)
        }
    }

    private var hiddenCountText: String {
        let off = store.hiddenSources.count
        return off == 0 ? "All shown" : "\(off) hidden"
    }

    // MARK: Behaviour

    /// Polls the freshness while the screen is visible, as the web does (once a minute).
    private func pollFreshness() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            if Task.isCancelled { return }
            await store.freshness.refresh()
        }
    }

    /// Handles a link to this module. `date` opens that day; `view` picks the view.
    private func apply(_ link: DeepLink?) {
        guard let link else { return }
        defer { app.consume(link) }
        if let raw = link.query["view"], let mode = CalendarViewMode(rawValue: raw) {
            storedView = mode.rawValue
        }
        if let raw = link.query["date"], let day = LocalDate(raw) {
            store.show(day)
            if link.query["view"] == nil, view == .agenda {
                storedView = CalendarViewMode.day.rawValue
            }
        }
    }
}

/// One line of the notice strip: a stale or failing source, or a source that failed to answer.
struct CalendarNotice: Identifiable, Sendable {
    let id: String
    let text: String
    let isError: Bool
}

/// The notices under the header (a stale source is visibly stale). Hidden when empty.
struct CalendarNoticeStrip: View {
    let notices: [CalendarNotice]
    /// Several notices fold into one line the person can open, so the header stays short on a phone.
    @State private var expanded = false

    var body: some View {
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                if notices.count > 1 {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label("\(notices.count) sources stale or failing",
                              systemImage: expanded ? "chevron.down" : "chevron.right")
                            // A finger-sized target (the accessibility audit's 44 pt).
                            .frame(minHeight: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Palette.status(.stale))
                    .accessibilityIdentifier("calendar.notices.toggle")
                }
                if expanded || notices.count == 1 {
                    ForEach(notices) { notice in
                        Label {
                            Text(notice.text)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                        }
                        .font(.caption)
                        .foregroundStyle(notice.isError ? Palette.status(.error) : Palette.status(.stale))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("calendar.notices")
        }
    }
}

#Preview {
    CalendarScreen().environment(AppEnvironment.preview())
}
