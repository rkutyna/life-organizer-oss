import OrganizerAPI
import OrganizerCore
import SwiftUI

// The list sections: a filter bar over a table. Double-click (or Return) opens a record; the
// context menu has the record's actions. Filters are part of each list's request (the store).

// MARK: - Applications

struct JobsApplicationsList: View {
    let store: JobsStore
    @State private var search: String
    @State private var selection: Set<Int> = []

    init(store: JobsStore) {
        self.store = store
        _search = State(initialValue: store.applicationSearch)
    }

    private var rows: [ApplicationOut] { store.applications.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            JobsFilterBar {
                JobsSearchField(prompt: "Title or company", text: $search)
                    .accessibilityIdentifier("jobs.applications.search")
                Picker("Status", selection: Binding(
                    get: { store.applicationStatus },
                    set: { store.setApplicationFilter(search: store.applicationSearch, status: $0) }
                )) {
                    Text("All statuses").tag(String?.none)
                    Divider()
                    ForEach(store.statusList.changeOptions, id: \.key) { status in
                        Text(status.label).tag(String?.some(status.key))
                    }
                    if let status = store.applicationStatus, !store.statusList.changeOptions.contains(where: { $0.key == status }) {
                        Text(store.label(status)).tag(String?.some(status))
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("jobs.applications.status")
            } trailing: {
                countText(rows.count, "application")
                Button {
                    store.sheet = .addApplication
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .accessibilityIdentifier("jobs.applications.add")
            }
            Divider()
            LoadingScaffold(
                status: store.status(.applications),
                isEmpty: rows.isEmpty,
                refresh: { await store.refresh(.applications) }
            ) {
                table
            } empty: {
                EmptyStateView(
                    store.applicationSearch.isEmpty && store.applicationStatus == nil ? "No applications yet" : "No matches",
                    systemImage: "tray",
                    message: store.applicationSearch.isEmpty && store.applicationStatus == nil
                        ? "Add one, or apply to a lead." : "Try another search or status.")
            }
        }
        .task(id: store.readKey(.applications)) { await store.load(.applications) }
        .task(id: search) {
            guard search != store.applicationSearch else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            store.setApplicationFilter(search: search, status: store.applicationStatus)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Title") { application in
                Text(application.title)
                    .fontWeight(.medium)
                    .help(application.title)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Company", value: \.company)
                .width(min: 90, ideal: 140)
            TableColumn("Status") { application in
                JobsStatusChip(store: store, status: application.status)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Applied") { application in
                Text(JobsFormat.day(application.dateApplied)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Reached") { application in
                Text(application.reached.map(store.label) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Next action") { application in
                JobsDueText(action: application.nextAction, due: application.nextActionDue)
            }
            .width(min: 100, ideal: 200)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, ids.count == 1, let application = rows.first(where: { $0.id == id }) {
                JobsApplicationMenu(store: store, application: application)
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(.application(id)) }
        }
        .accessibilityIdentifier("jobs.applications.table")
    }
}

/// An application's actions, for a context menu: open, the status (today), Apply and Drop for a
/// lead, edit, open on the web.
struct JobsApplicationMenu: View {
    let store: JobsStore
    let application: ApplicationOut
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        Button("Open") { store.open(.application(application.id)) }
        Divider()
        if store.isOpenLead(application) {
            Button("Apply…") { store.sheet = .apply(application) }
            Button("Drop…") { store.sheet = .drop(application) }
        } else {
            Menu("Status") {
                ForEach(store.statusList.changeOptions, id: \.key) { status in
                    Button {
                        Task { await store.quickChangeStatus(application.id, to: status.key) }
                    } label: {
                        if status.key == application.status {
                            Label(status.label, systemImage: "checkmark")
                        } else {
                            Text(status.label)
                        }
                    }
                    .disabled(status.key == application.status)
                }
            }
            Button("Change Status…") { store.sheet = .status(application) }
        }
        Button("Edit…") { store.sheet = .editApplication(application) }
        Divider()
        Link("Open in Web", destination: app.webURL(JobsRoute.application(application.id).webPath))
    }
}

// MARK: - Leads

struct JobsLeadsList: View {
    let store: JobsStore
    @State private var selection: Set<Int> = []

    private var rows: [ApplicationOut] { store.leads.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            JobsFilterBar {
                Toggle("Show dropped", isOn: Binding(
                    get: { store.includeDroppedLeads },
                    set: { store.setIncludeDroppedLeads($0) }
                ))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("jobs.leads.dropped")
            } trailing: {
                countText(rows.count, "lead")
            }
            Divider()
            LoadingScaffold(
                status: store.status(.leads),
                isEmpty: rows.isEmpty,
                refresh: { await store.refresh(.leads) }
            ) {
                table
            } empty: {
                EmptyStateView("No open leads", systemImage: "lightbulb",
                               message: "A lead is a posting you might apply to. Log one on the web or ask Claude.")
            }
        }
        .task(id: store.readKey(.leads)) { await store.load(.leads) }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Title") { lead in
                Text(lead.title).fontWeight(.medium).help(lead.title)
            }
            .width(min: 140, ideal: 220)
            TableColumn("Company", value: \.company)
                .width(min: 90, ideal: 140)
            TableColumn("Found") { lead in
                Text(JobsFormat.day(lead.foundOn)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Status") { lead in
                JobsStatusChip(store: store, status: lead.status)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Next action") { lead in
                JobsDueText(action: lead.nextAction, due: lead.nextActionDue)
            }
            .width(min: 90, ideal: 160)
            TableColumn("") { lead in
                if store.isOpenLead(lead) {
                    HStack(spacing: 6) {
                        Button("Apply…") { store.sheet = .apply(lead) }
                            .foregroundStyle(Palette.primary)
                            .accessibilityIdentifier("jobs.leads.apply.\(lead.id)")
                        Button("Drop…") { store.sheet = .drop(lead) }
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .width(min: 110, ideal: 120)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, ids.count == 1, let lead = rows.first(where: { $0.id == id }) {
                JobsApplicationMenu(store: store, application: lead)
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(.application(id)) }
        }
        .accessibilityIdentifier("jobs.leads.table")
    }
}

// MARK: - Contacts

struct JobsContactsList: View {
    let store: JobsStore
    @State private var search: String
    @State private var selection: Set<Int> = []

    init(store: JobsStore) {
        self.store = store
        _search = State(initialValue: store.contactSearch)
    }

    private var rows: [ContactOut] { store.contacts.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            JobsFilterBar {
                JobsSearchField(prompt: "Name, role or company", text: $search)
                    .accessibilityIdentifier("jobs.contacts.search")
            } trailing: {
                countText(rows.count, "contact")
                Button {
                    store.sheet = .addContact
                } label: {
                    Label("Add Contact", systemImage: "plus")
                }
                .accessibilityIdentifier("jobs.contacts.add")
            }
            Divider()
            LoadingScaffold(
                status: store.status(.contacts),
                isEmpty: rows.isEmpty,
                refresh: { await store.refresh(.contacts) }
            ) {
                table
            } empty: {
                EmptyStateView(store.contactSearch.isEmpty ? "No contacts yet" : "No matches",
                               systemImage: "person.2",
                               message: store.contactSearch.isEmpty ? "Add the people you talk to." : "Try another search.")
            }
        }
        .task(id: store.readKey(.contacts)) { await store.load(.contacts) }
        .task(id: search) {
            guard search != store.contactSearch else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            store.setContactSearch(search)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Name") { contact in
                Text(contact.name).fontWeight(.medium)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Company") { contact in
                Text(contact.company ?? "").foregroundStyle(contact.company == nil ? .secondary : .primary)
            }
            .width(min: 80, ideal: 130)
            TableColumn("Role", value: \.role)
                .width(min: 80, ideal: 140)
            TableColumn("Contacted") { contact in
                Text(JobsFormat.day(contact.contactedOn)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Replied") { contact in
                Text(JobsFormat.day(contact.repliedOn)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Next action") { contact in
                JobsDueText(action: contact.nextAction, due: contact.nextActionDue)
            }
            .width(min: 100, ideal: 200)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, ids.count == 1, let contact = rows.first(where: { $0.id == id }) {
                Button("Open") { store.open(.contact(id)) }
                Button("Edit…") { store.sheet = .editContact(contact) }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(.contact(id)) }
        }
        .accessibilityIdentifier("jobs.contacts.table")
    }
}

// MARK: - Interviews

struct JobsInterviewsList: View {
    let store: JobsStore
    @State private var selection: Set<Int> = []

    private var rows: [InterviewOut] { store.interviews.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            JobsFilterBar {
                Toggle("Upcoming only", isOn: Binding(
                    get: { store.upcomingInterviewsOnly },
                    set: { store.setUpcomingInterviewsOnly($0) }
                ))
                .toggleStyle(.checkbox)
            } trailing: {
                countText(rows.count, "interview")
            }
            Divider()
            LoadingScaffold(
                status: store.status(.interviews),
                isEmpty: rows.isEmpty,
                refresh: { await store.refresh(.interviews) }
            ) {
                table
            } empty: {
                EmptyStateView("No interviews", systemImage: "person.wave.2",
                               message: "Interviews recorded for an application show here and on the calendar.")
            }
        }
        .task(id: store.readKey(.interviews)) { await store.load(.interviews) }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("When") { interview in
                Text(JobsFormat.interviewWhen(interview))
                    .foregroundStyle(interview.onDate == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            .width(min: 140, ideal: 210)
            TableColumn("Stage") { interview in
                Text(interview.stage.isEmpty ? "Interview" : interview.stage).fontWeight(.medium)
            }
            .width(min: 70, ideal: 100)
            TableColumn("Company", value: \.company)
                .width(min: 80, ideal: 120)
            TableColumn("Application", value: \.applicationTitle)
                .width(min: 100, ideal: 180)
            TableColumn("Interviewer", value: \.interviewer)
                .width(min: 70, ideal: 110)
            TableColumn("Location", value: \.location)
                .width(min: 70, ideal: 110)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, ids.count == 1, let interview = rows.first(where: { $0.id == id }) {
                Button("Open") { store.open(.interview(id)) }
                Button("Open Application") { store.open(.application(interview.applicationId)) }
                Button("Edit…") { store.sheet = .editInterview(interview) }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(.interview(id)) }
        }
        .accessibilityIdentifier("jobs.interviews.table")
    }
}

// MARK: - Events

struct JobsEventsList: View {
    let store: JobsStore
    @State private var selection: Set<Int> = []

    private var rows: [JobEventOut] { store.events.value ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            JobsFilterBar {
                Toggle("Upcoming only", isOn: Binding(
                    get: { store.upcomingEventsOnly },
                    set: { store.setUpcomingEventsOnly($0) }
                ))
                .toggleStyle(.checkbox)
            } trailing: {
                countText(rows.count, "event")
            }
            Divider()
            LoadingScaffold(
                status: store.status(.events),
                isEmpty: rows.isEmpty,
                refresh: { await store.refresh(.events) }
            ) {
                table
            } empty: {
                EmptyStateView("No events", systemImage: "calendar.badge.clock",
                               message: "Career fairs, networking evenings and info sessions show here.")
            }
        }
        .task(id: store.readKey(.events)) { await store.load(.events) }
    }

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn("Day") { event in
                Text(JobsFormat.longDay(event.onDate)).monospacedDigit()
            }
            .width(min: 80, ideal: 110)
            TableColumn("Name") { event in
                Text(event.name).fontWeight(.medium).help(event.name)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Kind", value: \.kind)
                .width(min: 50, ideal: 80)
            TableColumn("Time") { event in
                Text(JobsFormat.eventTimes(event)).monospacedDigit()
            }
            .width(min: 70, ideal: 140)
            TableColumn("Location", value: \.location)
                .width(min: 80, ideal: 150)
            TableColumn("Attended") { event in
                if event.attended != nil {
                    JobsChip(JobsFormat.attended(event.attended),
                             tone: event.attended == true ? Palette.status(.ok) : Palette.status(.done))
                }
            }
            .width(min: 60, ideal: 70)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, ids.count == 1, let event = rows.first(where: { $0.id == id }) {
                Button("Open") { store.open(.event(id)) }
                Button("Edit…") { store.sheet = .editEvent(event) }
            }
        } primaryAction: { ids in
            if let id = ids.first { store.open(.event(id)) }
        }
        .accessibilityIdentifier("jobs.events.table")
    }
}

/// "3 applications", in the filter bar.
private func countText(_ count: Int, _ noun: String) -> some View {
    Text("\(count) \(count == 1 ? noun : noun + "s")")
        .font(.callout)
        .foregroundStyle(.secondary)
        .monospacedDigit()
}
