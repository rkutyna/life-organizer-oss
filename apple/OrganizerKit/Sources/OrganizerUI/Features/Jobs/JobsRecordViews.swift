import OrganizerAPI
import OrganizerCore
import SwiftUI

// The record screens pushed on the Jobs stack: an application (or lead), a contact, an
// interview, an event. Each opens with the list's copy at once, then fetches its own.

/// A record screen for any route.
struct JobsRouteView: View {
    let store: JobsStore
    let route: JobsRoute

    var body: some View {
        switch route {
        case .application(let id): JobsApplicationDetailView(store: store, id: id)
        case .contact(let id): JobsContactDetailView(store: store, id: id)
        case .interview(let id): JobsInterviewDetailView(store: store, id: id)
        case .event(let id): JobsEventDetailView(store: store, id: id)
        }
    }
}

/// A record screen's header: a title, a line under it, and the actions.
private struct JobsRecordHeader<Accessory: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                actions
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Application

struct JobsApplicationDetailView: View {
    let store: JobsStore
    let id: Int

    var body: some View {
        let detail = store.applicationDetail(id)
        let application = store.application(id)
        LoadingScaffold(
            status: store.recordStatus(detail.application, hasCopy: application != nil),
            refresh: { await detail.load(force: true) }
        ) {
            if let application {
                form(application, detail: detail)
            }
        }
        .navigationTitle(application?.title ?? "Application")
        .task(id: id) { await detail.load() }
    }

    private func form(_ application: ApplicationOut, detail: JobsApplicationDetail) -> some View {
        let isLead = store.isOpenLead(application)
        let kind = store.kind(application.status)
        return Form {
            Section {
                JobsRecordHeader(title: application.title, subtitle: subtitle(application)) {
                    JobsStatusChip(store: store, status: application.status)
                    if let reached = application.reached, reached != application.status {
                        Text("reached \(store.label(reached))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } actions: {
                    if isLead {
                        Button {
                            store.sheet = .apply(application)
                        } label: {
                            Label("Apply…", systemImage: "paperplane")
                        }
                        .accessibilityIdentifier("jobs.application.apply")
                        Button {
                            store.sheet = .drop(application)
                        } label: {
                            Label("Drop…", systemImage: "xmark.bin")
                        }
                    } else if kind != .dropped {
                        Menu {
                            ForEach(store.statusList.changeOptions, id: \.key) { status in
                                Button(status.label) {
                                    Task { await store.quickChangeStatus(application.id, to: status.key) }
                                }
                                .disabled(status.key == application.status)
                            }
                            Divider()
                            Button("With a Date and Note…") { store.sheet = .status(application) }
                        } label: {
                            Label("Status", systemImage: "arrow.triangle.branch")
                        } primaryAction: {
                            store.sheet = .status(application)
                        }
                        .fixedSize()
                        .help("Change the status")
                        .accessibilityIdentifier("jobs.application.status")
                    }
                    Button {
                        store.sheet = .editApplication(application)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityIdentifier("jobs.application.edit")
                    Spacer()
                    OpenInWebLink(path: JobsRoute.application(application.id).webPath)
                }
            }

            Section("Details") {
                JobsFieldRow("Applied", application.dateApplied.map { JobsFormat.longDay($0) } ?? "")
                JobsFieldRow("Found", application.foundOn.map { JobsFormat.longDay($0) } ?? "")
                JobsFieldRow("Location", application.location)
                JobsLinkRow(label: "Posting", value: application.postingUrl)
                JobsFieldRow("Source", application.source)
                if !application.nextAction.isEmpty || application.nextActionDue != nil {
                    LabeledContent("Next action") {
                        JobsDueText(action: application.nextAction, due: application.nextActionDue)
                    }
                }
                JobsTagsRow(tags: application.tags)
            }

            JobsNotesSection(notes: application.notes)

            Section("Status history") {
                if let history = detail.history.value {
                    if history.isEmpty {
                        Text("No status recorded yet").foregroundStyle(.secondary)
                    }
                    ForEach(history) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(JobsFormat.longDay(event.onDate))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            JobsStatusChip(store: store, status: event.status)
                            if !event.note.isEmpty {
                                Text(event.note)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                } else if let error = detail.history.state.error {
                    Text(error.message).foregroundStyle(Palette.status(.error))
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section("Interviews") {
                let interviews = detail.interviews.value ?? []
                if interviews.isEmpty {
                    Text(detail.interviews.value == nil ? "Loading…" : "No interviews").foregroundStyle(.secondary)
                }
                ForEach(interviews) { interview in
                    NavigationLink(value: JobsRoute.interview(interview.id)) {
                        LabeledContent(interview.stage.isEmpty ? "Interview" : interview.stage,
                                       value: JobsFormat.interviewWhen(interview))
                    }
                }
            }

            Section("Contacts at \(application.company)") {
                let contacts = detail.contacts?.value ?? []
                if contacts.isEmpty {
                    Text(detail.contacts?.value == nil ? "Loading…" : "No contacts at this company").foregroundStyle(.secondary)
                }
                ForEach(contacts) { contact in
                    NavigationLink(value: JobsRoute.contact(contact.id)) {
                        LabeledContent(contact.name, value: contact.role)
                    }
                }
            }

            if !application.extra.isEmpty {
                Section("Imported columns") {
                    ForEach(application.extra.keys.sorted(), id: \.self) { key in
                        JobsFieldRow(key, application.extra[key] ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("jobs.application.detail")
    }

    private func subtitle(_ application: ApplicationOut) -> String {
        var parts = [application.company]
        if let applied = application.dateApplied { parts.append("applied \(JobsFormat.day(applied))") }
        if !application.location.isEmpty { parts.append(application.location) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Contact

struct JobsContactDetailView: View {
    let store: JobsStore
    let id: Int

    var body: some View {
        let read = store.contactRead(id)
        let contact = store.contact(id)
        LoadingScaffold(status: store.recordStatus(read, hasCopy: contact != nil), refresh: { await read.refresh() }) {
            if let contact {
                form(contact)
            }
        }
        .navigationTitle(contact?.name ?? "Contact")
        .task(id: id) { await read.refreshIfStale() }
    }

    private func form(_ contact: ContactOut) -> some View {
        Form {
            Section {
                JobsRecordHeader(title: contact.name, subtitle: [contact.role, contact.company ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) {
                    EmptyView()
                } actions: {
                    Button {
                        store.sheet = .editContact(contact)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityIdentifier("jobs.contact.edit")
                    Spacer()
                    OpenInWebLink(path: JobsRoute.contact(contact.id).webPath)
                }
            }
            Section("Details") {
                if !contact.email.isEmpty {
                    LabeledContent("Email") {
                        if let url = URL(string: "mailto:\(contact.email)") {
                            Link(contact.email, destination: url)
                        } else {
                            Text(contact.email).textSelection(.enabled)
                        }
                    }
                }
                JobsLinkRow(label: "Profile", value: contact.profileUrl)
                JobsFieldRow("Contacted", contact.contactedOn.map { JobsFormat.longDay($0) } ?? "")
                JobsFieldRow("Replied", contact.repliedOn.map { JobsFormat.longDay($0) } ?? "")
                if !contact.nextAction.isEmpty || contact.nextActionDue != nil {
                    LabeledContent("Next action") {
                        JobsDueText(action: contact.nextAction, due: contact.nextActionDue)
                    }
                }
                JobsTagsRow(tags: contact.tags)
                if contact.email.isEmpty && contact.profileUrl.isEmpty && contact.contactedOn == nil
                    && contact.nextAction.isEmpty && contact.tags.isEmpty {
                    Text("Nothing recorded yet").foregroundStyle(.secondary)
                }
            }
            JobsNotesSection(notes: contact.notes)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("jobs.contact.detail")
    }
}

// MARK: - Interview

struct JobsInterviewDetailView: View {
    let store: JobsStore
    let id: Int

    var body: some View {
        let read = store.interviewRead(id)
        let interview = store.interview(id)
        LoadingScaffold(status: store.recordStatus(read, hasCopy: interview != nil), refresh: { await read.refresh() }) {
            if let interview {
                form(interview)
            }
        }
        .navigationTitle(interview.map(title) ?? "Interview")
        .task(id: id) { await read.refreshIfStale() }
    }

    private func title(_ interview: InterviewOut) -> String {
        "\(interview.stage.isEmpty ? "Interview" : interview.stage): \(interview.company)"
    }

    private func form(_ interview: InterviewOut) -> some View {
        Form {
            Section {
                JobsRecordHeader(title: title(interview), subtitle: JobsFormat.interviewWhen(interview)) {
                    EmptyView()
                } actions: {
                    Button {
                        store.sheet = .editInterview(interview)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityIdentifier("jobs.interview.edit")
                    Spacer()
                    OpenInWebLink(path: JobsRoute.application(interview.applicationId).webPath)
                }
            }
            Section("Details") {
                NavigationLink(value: JobsRoute.application(interview.applicationId)) {
                    LabeledContent("Application", value: "\(interview.applicationTitle) at \(interview.company)")
                }
                JobsLinkRow(label: "Location", value: interview.location)
                JobsFieldRow("Interviewer", interview.interviewer)
                JobsFieldRow("Duration", interview.durationMinutes.map { "\($0) min" } ?? "")
            }
            JobsNotesSection(notes: interview.notes)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("jobs.interview.detail")
    }
}

// MARK: - Event

struct JobsEventDetailView: View {
    let store: JobsStore
    let id: Int

    var body: some View {
        let read = store.eventRead(id)
        let event = store.event(id)
        LoadingScaffold(status: store.recordStatus(read, hasCopy: event != nil), refresh: { await read.refresh() }) {
            if let event {
                form(event)
            }
        }
        .navigationTitle(event?.name ?? "Event")
        .task(id: id) { await read.refreshIfStale() }
    }

    private func form(_ event: JobEventOut) -> some View {
        Form {
            Section {
                JobsRecordHeader(title: event.name, subtitle: JobsFormat.eventWhen(event)) {
                    if !event.kind.isEmpty {
                        Text(event.kind)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if event.attended != nil {
                        JobsChip(JobsFormat.attended(event.attended),
                                 tone: event.attended == true ? Palette.status(.ok) : Palette.status(.done))
                    }
                } actions: {
                    Button {
                        store.sheet = .editEvent(event)
                    } label: {
                        Label("Edit…", systemImage: "pencil")
                    }
                    .keyboardShortcut("e", modifiers: .command)
                    .accessibilityIdentifier("jobs.event.edit")
                    Spacer()
                    OpenInWebLink(path: JobsRoute.event(event.id).webPath)
                }
            }
            Section("Details") {
                JobsFieldRow("Location", event.location)
                JobsLinkRow(label: "Link", value: event.url)
                JobsFieldRow("Attended", JobsFormat.attended(event.attended))
                JobsTagsRow(tags: event.tags)
                if event.location.isEmpty && event.url.isEmpty && event.attended == nil && event.tags.isEmpty {
                    Text("Nothing recorded yet").foregroundStyle(.secondary)
                }
            }
            JobsNotesSection(notes: event.notes)
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("jobs.event.detail")
    }
}
