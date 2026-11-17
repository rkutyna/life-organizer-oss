import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The sheets the screen shows, from any section or record (`store.sheet`).
nonisolated enum JobsSheet: Identifiable, Sendable {
    case status(ApplicationOut)
    case apply(ApplicationOut)
    case drop(ApplicationOut)
    case editApplication(ApplicationOut)
    case addApplication
    case addContact
    case editContact(ContactOut)
    case editInterview(InterviewOut)
    case editEvent(JobEventOut)

    var id: String {
        switch self {
        case .status(let application): "status-\(application.id)"
        case .apply(let application): "apply-\(application.id)"
        case .drop(let application): "drop-\(application.id)"
        case .editApplication(let application): "application-\(application.id)"
        case .addApplication: "add-application"
        case .addContact: "add-contact"
        case .editContact(let contact): "contact-\(contact.id)"
        case .editInterview(let interview): "interview-\(interview.id)"
        case .editEvent(let event): "event-\(event.id)"
        }
    }
}

struct JobsSheetView: View {
    let store: JobsStore
    let sheet: JobsSheet

    var body: some View {
        switch sheet {
        case .status(let application): JobsStatusSheet(store: store, application: application)
        case .apply(let lead): JobsApplySheet(store: store, lead: lead)
        case .drop(let lead): JobsDropSheet(store: store, lead: lead)
        case .editApplication(let application): JobsApplicationSheet(store: store, original: application)
        case .addApplication: JobsApplicationSheet(store: store, original: nil)
        case .addContact: JobsContactSheet(store: store, original: nil)
        case .editContact(let contact): JobsContactSheet(store: store, original: contact)
        case .editInterview(let interview): JobsInterviewSheet(store: store, original: interview)
        case .editEvent(let event): JobsEventSheet(store: store, original: event)
        }
    }
}

// MARK: - Status, Apply, Drop

/// A dated status change with an optional note. The statuses are the server's active and
/// closed ones, in list order.
struct JobsStatusSheet: View {
    let store: JobsStore
    let application: ApplicationOut
    @State private var status = ""
    @State private var day = LocalDate.today()
    @State private var note = ""

    private var options: [JobStatusOut] { store.statusList.changeOptions }

    /// The pick, else the stage after the current one in list order, else the first other status.
    private var chosen: String {
        guard status.isEmpty else { return status }
        if let index = options.firstIndex(where: { $0.key == application.status }),
           index + 1 < options.count, options[index + 1].kind == .active {
            return options[index + 1].key
        }
        return options.first { $0.key != application.status }?.key ?? ""
    }

    var body: some View {
        JobsSheetScaffold(title: "Change Status", saveTitle: "Change Status", canSave: !chosen.isEmpty) {
            try await store.changeStatus(application.id, to: chosen, on: day, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        } content: {
            Section {
                LabeledContent("Application", value: "\(application.title) at \(application.company)")
                LabeledContent("Now") { JobsStatusChip(store: store, status: application.status) }
            }
            Section {
                Picker("New status", selection: Binding(get: { chosen }, set: { status = $0 })) {
                    ForEach(options, id: \.key) { option in
                        Text(option.label).tag(option.key)
                    }
                }
                .accessibilityIdentifier("jobs.status.picker")
                DatePicker("On", selection: JobsBindings.date($day), displayedComponents: .date)
                TextField("Note", text: $note, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(1...4)
            } footer: {
                Text("A change dated before the latest one is recorded in the history but leaves the status as it is.")
            }
        }
        .task { await store.statuses.refreshIfStale(maxAge: 300) }
    }
}

/// Submits an open lead: it becomes an application on the day picked.
struct JobsApplySheet: View {
    let store: JobsStore
    let lead: ApplicationOut
    @State private var day = LocalDate.today()

    var body: some View {
        JobsSheetScaffold(title: "Apply to Lead", saveTitle: "Apply", canSave: true) {
            try await store.apply(leadID: lead.id, on: day)
        } content: {
            Section {
                DatePicker("Applied on", selection: JobsBindings.date($day), displayedComponents: .date)
            } footer: {
                Text("\(lead.title) at \(lead.company) becomes an application. The day can't be before the day the lead was found.")
            }
        }
        .frame(idealHeight: 260)
    }
}

/// Cuts an open lead without applying; the reason is kept in its history and notes.
struct JobsDropSheet: View {
    let store: JobsStore
    let lead: ApplicationOut
    @State private var reason = ""

    var body: some View {
        JobsSheetScaffold(title: "Drop Lead", saveTitle: "Drop Lead",
                          canSave: !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            try await store.drop(leadID: lead.id, reason: reason)
        } content: {
            Section {
                TextField("Reason", text: $reason, prompt: Text("Required, e.g. needs relocation"))
                    .accessibilityIdentifier("jobs.drop.reason")
            } footer: {
                Text("\(lead.title) at \(lead.company) is cut without applying.")
            }
        }
        .frame(idealHeight: 260)
    }
}

// MARK: - Applications

/// Edits an application's main fields, or adds one (`original` nil).
struct JobsApplicationSheet: View {
    let store: JobsStore
    let original: ApplicationOut?
    @State private var draft: JobsApplicationDraft

    init(store: JobsStore, original: ApplicationOut?) {
        self.store = store
        self.original = original
        if let original {
            _draft = State(initialValue: JobsApplicationDraft(original))
        } else {
            var draft = JobsApplicationDraft()
            draft.dateApplied = .today()
            draft.status = store.statusList.changeOptions.first?.key
            _draft = State(initialValue: draft)
        }
    }

    private var isLead: Bool { original.map(store.isOpenLead) ?? false }

    var body: some View {
        JobsSheetScaffold(
            title: original == nil ? "Add Application" : "Edit Application",
            saveTitle: original == nil ? "Add" : "Save",
            canSave: original == nil ? draft.canCreate : draft.canSaveEdit
        ) {
            if let original {
                try await store.updateApplication(original, with: draft)
            } else {
                let id = try await store.createApplication(draft)
                store.open(.application(id))
            }
        } content: {
            Section {
                TextField("Title", text: $draft.title, prompt: Text("Required"))
                    .accessibilityIdentifier("jobs.application.title")
                if let original {
                    JobsCompanyPicker(store: store, companyID: $draft.companyID, currentName: original.company)
                } else {
                    JobsCompanyNameField(store: store, name: $draft.companyName, companyID: $draft.companyID)
                    Picker("Status", selection: $draft.status) {
                        if store.statusList.isEmpty {
                            Text("Default").tag(String?.none)
                        }
                        ForEach(store.statusList.changeOptions, id: \.key) { status in
                            Text(status.label).tag(String?.some(status.key))
                        }
                    }
                }
                if isLead {
                    LabeledContent("Date applied") {
                        Text("None: Apply submits a lead").foregroundStyle(.secondary)
                    }
                } else {
                    JobsOptionalDateField(label: "Date applied", day: $draft.dateApplied)
                }
            }
            Section {
                TextField("Location", text: $draft.location)
                TextField("Posting", text: $draft.postingURL, prompt: Text("https://jobs.example.com/…"))
                TextField("Source", text: $draft.source, prompt: Text("Where you found it"))
                TextField("Tags", text: $draft.tags, prompt: Text("Comma separated"))
            }
            Section {
                TextField("Next action", text: $draft.nextAction)
                JobsOptionalDateField(label: "Due", day: $draft.nextActionDue)
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
        }
    }
}

/// A company by name for a new record: type one (a new name creates it) or pick an existing one.
struct JobsCompanyNameField: View {
    let store: JobsStore
    @Binding var name: String
    @Binding var companyID: Int?
    var prompt = "Required"

    var body: some View {
        LabeledContent("Company") {
            HStack(spacing: 6) {
                TextField("Company", text: Binding(
                    get: { name },
                    set: { text in
                        name = text
                        // A typed name is matched by the server; a picked one is sent by id.
                        if store.companies.value?.first(where: { $0.id == companyID })?.name != text {
                            companyID = nil
                        }
                    }
                ), prompt: Text(prompt))
                .labelsHidden()
                .accessibilityIdentifier("jobs.company.name")
                Menu {
                    ForEach(store.companies.value ?? []) { company in
                        Button(company.name) {
                            name = company.name
                            companyID = company.id
                        }
                    }
                } label: {
                    Image(systemName: "building.2")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled((store.companies.value ?? []).isEmpty)
                .help("Pick a company")
                .accessibilityLabel("Pick a company")
            }
        }
        .task { await store.loadCompanies() }
    }
}

// MARK: - Contacts

/// Edits a contact, or adds one (`original` nil).
struct JobsContactSheet: View {
    let store: JobsStore
    let original: ContactOut?
    @State private var draft: JobsContactDraft

    init(store: JobsStore, original: ContactOut?) {
        self.store = store
        self.original = original
        _draft = State(initialValue: original.map(JobsContactDraft.init) ?? JobsContactDraft())
    }

    var body: some View {
        JobsSheetScaffold(
            title: original == nil ? "Add Contact" : "Edit Contact",
            saveTitle: original == nil ? "Add" : "Save",
            canSave: draft.canSave
        ) {
            if let original {
                try await store.updateContact(original, with: draft)
            } else {
                let id = try await store.createContact(draft)
                store.open(.contact(id))
            }
        } content: {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                    .accessibilityIdentifier("jobs.contact.name")
                if let original {
                    JobsCompanyPicker(store: store, companyID: $draft.companyID, allowsNone: true, currentName: original.company)
                } else {
                    JobsCompanyNameField(store: store, name: $draft.companyName, companyID: $draft.companyID, prompt: "Optional")
                }
                TextField("Role", text: $draft.role)
                TextField("Email", text: $draft.email)
                TextField("Profile", text: $draft.profileURL, prompt: Text("https://…"))
                TextField("Tags", text: $draft.tags, prompt: Text("Comma separated"))
            }
            Section {
                JobsOptionalDateField(label: "Contacted on", day: $draft.contactedOn)
                JobsOptionalDateField(label: "Replied on", day: $draft.repliedOn)
            }
            Section {
                TextField("Next action", text: $draft.nextAction)
                JobsOptionalDateField(label: "Due", day: $draft.nextActionDue)
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
        }
    }
}

// MARK: - Interviews and events

struct JobsInterviewSheet: View {
    let store: JobsStore
    let original: InterviewOut
    @State private var draft: JobsInterviewDraft

    init(store: JobsStore, original: InterviewOut) {
        self.store = store
        self.original = original
        _draft = State(initialValue: JobsInterviewDraft(original))
    }

    var body: some View {
        JobsSheetScaffold(title: "Edit Interview", saveTitle: "Save", canSave: draft.canSave) {
            try await store.updateInterview(original, with: draft)
        } content: {
            Section {
                LabeledContent("Application", value: "\(original.applicationTitle) at \(original.company)")
                TextField("Stage", text: $draft.stage, prompt: Text("Screen, Technical, Onsite…"))
            }
            Section {
                JobsOptionalDateField(label: "Day", day: $draft.onDate)
                if draft.onDate != nil {
                    JobsOptionalTimeField(label: "Start", time: $draft.startTime)
                }
                TextField("Duration (min)", text: JobsBindings.minutes($draft.durationMinutes), prompt: Text("60"))
            } footer: {
                if !draft.canSave {
                    Text("A duration is 5 minutes to a day.")
                        .foregroundStyle(Palette.status(.error))
                }
            }
            Section {
                TextField("Location", text: $draft.location, prompt: Text("A place or a video link"))
                TextField("Interviewer", text: $draft.interviewer)
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
        }
    }
}

struct JobsEventSheet: View {
    let store: JobsStore
    let original: JobEventOut
    @State private var draft: JobsEventDraft

    init(store: JobsStore, original: JobEventOut) {
        self.store = store
        self.original = original
        _draft = State(initialValue: JobsEventDraft(original))
    }

    var body: some View {
        JobsSheetScaffold(title: "Edit Event", saveTitle: "Save", canSave: draft.canSave) {
            try await store.updateEvent(original, with: draft)
        } content: {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("Required"))
                TextField("Kind", text: $draft.kind, prompt: Text("Fair, networking, info session"))
            }
            Section {
                DatePicker("Day", selection: JobsBindings.date($draft.onDate), displayedComponents: .date)
                JobsOptionalTimeField(label: "Start", time: $draft.startTime, defaultTime: LocalTime(hour: 18, minute: 0))
                if let start = draft.startTime {
                    JobsOptionalTimeField(label: "End", time: $draft.endTime,
                                          defaultTime: LocalTime(hour: min(start.hour + 2, 23), minute: start.minute))
                }
            } footer: {
                if let start = draft.startTime, let end = draft.endTime, end < start {
                    Text("The end is before the start.")
                        .foregroundStyle(Palette.status(.error))
                }
            }
            Section {
                TextField("Location", text: $draft.location)
                TextField("Link", text: $draft.url, prompt: Text("https://…"))
                Picker("Attended", selection: $draft.attended) {
                    Text("Not recorded").tag(Bool?.none)
                    Text("Went").tag(Bool?.some(true))
                    Text("Missed").tag(Bool?.some(false))
                }
                TextField("Tags", text: $draft.tags, prompt: Text("Comma separated"))
            }
            Section {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)
            }
        }
    }
}
