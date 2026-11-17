import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The Reminders module's root screen (the registry names this type; keep the name). Reminders
/// from Apple Reminders (through the Mac helper) and Google Tasks: the views and lists on the left,
/// quick-add on top, and the reminders by section.
struct RemindersScreen: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        RemindersView(store: app.store { RemindersStore(client: $0) })
    }
}

/// The edit sheet's subject (a reminder may be opened by a deep link before it is loaded).
struct RemindersEditing: Identifiable {
    let reminder: ReminderOut
    var id: Int { reminder.id }
}

/// Handles `lifeorganizer://reminders?reminder=<id>` (opens that reminder's editor) and
/// `?list=<id>` (shows that list).
struct RemindersView: View {
    @Bindable var store: RemindersStore
    @Environment(AppEnvironment.self) private var app
    @AppStorage("reminders.scope") private var scopeKey = RemindersScope.today.storageKey
    @AppStorage("reminders.showCompleted") private var showCompleted = false
    @State private var selection: Set<Int> = []
    @State private var editing: RemindersEditing?
    @State private var quickAddText = ""
    @State private var showingStatus = false
    @FocusState private var quickAddFocused: Bool

    private var scope: RemindersScope {
        RemindersScope(storageKey: scopeKey) ?? .today
    }

    private var scopeBinding: Binding<RemindersScope> {
        Binding(get: { scope }, set: { scopeKey = $0.storageKey })
    }

    private var sections: [RemindersSection] { store.sections(for: scope) }

    var body: some View {
        ModuleNavigationStack {
            HStack(spacing: 0) {
                RemindersSidebar(store: store, scope: scopeBinding)
                    .frame(width: 230)
                Divider()
                VStack(spacing: 0) {
                    VStack(spacing: 8) {
                        RemindersQuickAddBar(store: store, viewingListID: scope.listID,
                                             text: $quickAddText, focused: $quickAddFocused)
                        banner
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    LoadingScaffold(status: store.loadStatus, isEmpty: sections.isEmpty, refresh: store.refresh) {
                        list
                    } empty: {
                        emptyState
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .navigationSubtitle(store.reminders.value == nil ? "" : "\(store.openCount(for: scope)) open")
            .toolbar { toolbar }
            .sheet(item: $editing) { editing in
                RemindersEditSheet(store: store, reminder: editing.reminder)
            }
            .notices($store.notice)
            .task { await store.refresh() }
            .task(id: store.pollInterval) { await poll(every: store.pollInterval) }
            .task(id: app.deepLink(for: .reminders)?.id) { await open(app.deepLink(for: .reminders)) }
            .task(id: QuickAddFocus.shared.requests) { await focusQuickAddIfAsked() }
            .onChange(of: scopeKey) { selection = [] }
        }
    }

    private var title: String {
        switch scope {
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .all: "Reminders"
        case .list(let id): store.list(id)?.title ?? "Reminders"
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                if section.isCompleted {
                    completedSection(section)
                } else {
                    Section {
                        rows(section.reminders)
                    } header: {
                        sectionHeader(section)
                    }
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Int.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            if let id = ids.first, let reminder = store.reminder(id) { edit(reminder) }
        }
        .onKeyPress(.space) {
            let chosen = selected
            guard !chosen.isEmpty else { return .ignored }
            for reminder in chosen { Task { await store.toggle(reminder) } }
            return .handled
        }
        .onKeyPress(.return) {
            guard let reminder = selected.first else { return .ignored }
            edit(reminder)
            return .handled
        }
        .accessibilityIdentifier("reminders.list")
    }

    private var selected: [ReminderOut] {
        selection.compactMap(store.reminder)
    }

    /// Completed recently is folded until opened, as on the web.
    private func completedSection(_ section: RemindersSection) -> some View {
        Section(isExpanded: $showCompleted) {
            rows(section.reminders)
        } header: {
            sectionHeader(section)
        }
    }

    private func sectionHeader(_ section: RemindersSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .foregroundStyle(section.isOverdue ? Palette.status(.overdue) : .secondary)
            Text("\(section.reminders.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            if case .day(let day) = section.kind, DayLabels.day(day) != DayLabels.long(day) {
                Text(DayLabels.long(day))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func rows(_ reminders: [ReminderOut]) -> some View {
        ForEach(reminders, id: \.id) { reminder in
            RemindersRow(
                reminder: reminder,
                today: store.today(),
                showList: scope.listID == nil,
                showsDay: scope != .upcoming,
                locked: store.isLocked(reminder),
                onToggle: { Task { await store.toggle(reminder) } },
                onRetry: { Task { await store.retryFailed(reminder) } },
                onWithdraw: { Task { await store.withdrawFailed(reminder) } }
            )
            .tag(reminder.id)
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<Int>) -> some View {
        let chosen = ids.compactMap(store.reminder)
        if chosen.count == 1, let reminder = chosen.first {
            Button {
                edit(reminder)
            } label: {
                Label(store.isLocked(reminder) ? "Show Details…" : "Edit…", systemImage: "pencil")
            }
        }
        let togglable = chosen.filter { !store.isLocked($0) }
        if !togglable.isEmpty {
            let allDone = togglable.allSatisfy(\.completed)
            Button {
                for reminder in togglable where reminder.completed == allDone {
                    Task { await store.toggle(reminder) }
                }
            } label: {
                Label(allDone ? "Mark Not Done" : "Mark Done", systemImage: allDone ? "circle" : "checkmark.circle")
            }
        }
        let failed = chosen.filter { !$0.failedOps.isEmpty }
        if !failed.isEmpty {
            Divider()
            Button {
                for reminder in failed { Task { await store.retryFailed(reminder) } }
            } label: {
                Label("Retry Failed Change", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
                for reminder in failed { Task { await store.withdrawFailed(reminder) } }
            } label: {
                Label("Withdraw Failed Change", systemImage: "arrow.uturn.backward")
            }
        }
        if chosen.count == 1, let reminder = chosen.first {
            Divider()
            OpenInWebLink(path: "/reminders?reminder=\(reminder.id)")
        }
    }

    // MARK: Chrome

    /// Calm on purpose (web: HelperBanner): queued Apple changes wait for the Mac.
    @ViewBuilder
    private var banner: some View {
        if store.status.value?.waitingForDevice == true {
            Label("Apple Reminders changes will apply when your Mac is awake and the helper is running.",
                  systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("reminders.helperBanner")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let summary = RemindersSyncSummary(store.status.value)
            Button {
                showingStatus.toggle()
            } label: {
                Label(summary.title, systemImage: summary.systemImage)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(summary.tone == .ok ? Color.secondary : remindersToneColor(summary.tone))
            }
            .help("Sync status")
            .popover(isPresented: $showingStatus, arrowEdge: .bottom) {
                RemindersStatusPanel(store: store)
            }
            .accessibilityIdentifier("reminders.status")

            Button {
                Task { await store.syncNow() }
            } label: {
                if store.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(store.isSyncing)
            .help("Poll Google Tasks now and reload. Apple Reminders syncs whenever the Mac helper pushes.")
            .accessibilityLabel("Sync Now")
            .accessibilityIdentifier("reminders.syncNow")

            OpenInWebLink(path: webPath)
                .labelStyle(.iconOnly)
                .help("Open in Web")
        }
    }

    private var webPath: String {
        if let id = scope.listID, let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            return "/reminders?list=\(encoded)"
        }
        return "/reminders"
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.hasNoSources {
            EmptyStateView("No reminders yet", systemImage: "checklist",
                           message: "Connect a Google account with Tasks in Settings, or install the Mac helper to sync Apple Reminders.")
        } else {
            switch scope {
            case .today:
                EmptyStateView("Nothing due today", systemImage: "checkmark.circle",
                               message: "Add one above. Dates like “friday 9am” or “next tue” are understood.")
            case .upcoming:
                EmptyStateView("Nothing upcoming", systemImage: "calendar",
                               message: "Reminders due after today show here, by day.")
            case .all, .list:
                EmptyStateView("Nothing here", systemImage: "checklist",
                               message: "Add one above. Dates like “friday 9am” or “next tue” are understood.")
            }
        }
    }

    // MARK: Behaviour

    private func edit(_ reminder: ReminderOut) {
        editing = RemindersEditing(reminder: reminder)
    }

    /// File › New Reminder (⌘N) bumps `QuickAddFocus.requests`; one made before the screen
    /// appeared is honored when it does.
    private func focusQuickAddIfAsked() async {
        let requests = QuickAddFocus.shared.requests
        guard requests > store.focusRequestsSeen else { return }
        store.focusRequestsSeen = requests
        // The field takes focus only once it is in a window.
        try? await Task.sleep(for: .milliseconds(100))
        quickAddFocused = true
    }

    /// Polls while the screen is visible: fast while a change is on its way, slowly otherwise.
    /// Restarts when the interval changes.
    private func poll(every interval: Duration) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            await store.poll()
        }
    }

    /// Handles a link to this module: `reminder=<id>` opens its editor, `list=<id>` shows the list.
    private func open(_ link: DeepLink?) async {
        guard let link else { return }
        defer { app.consume(link) }
        if let id = link.query["list"], !id.isEmpty {
            scopeKey = RemindersScope.list(id).storageKey
        }
        if let id = link.query["reminder"].flatMap(Int.init) {
            if let reminder = await store.find(id) {
                selection = [id]
                edit(reminder)
            }
        }
    }
}

#Preview {
    RemindersScreen().environment(AppEnvironment.preview())
        .frame(width: 1000, height: 700)
}
