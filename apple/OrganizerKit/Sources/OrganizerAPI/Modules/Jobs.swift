import Foundation

extension OrganizerClient {
    /// The job tracker: `/api/jobs` (docs/JOBS.md).
    ///
    /// A lead is an application whose status is `lead`: Apply submits it and Drop cuts it, on the
    /// same record. The status list is the server's and is configurable, so a client never
    /// hardcodes it: read `statuses()` and use `[JobStatusOut].label(for:)` / `kind(of:)`.
    public var jobs: JobsAPI { JobsAPI(client: self) }
}

public struct JobsAPI: Sendable {
    let client: OrganizerClient

    // MARK: Reads (one-off; screens read through `Resource`)

    /// The status list, in order.
    public func statuses() async throws -> [JobStatusOut] {
        try await client.send(API.Jobs.listStatuses())
    }

    /// Counts by current status and by how far applications got. Counts, never rates.
    public func pipeline() async throws -> PipelineOut {
        try await client.send(API.Jobs.getPipeline())
    }

    // MARK: Applications and leads

    /// Appends a dated status event (today when `on` is nil). The status follows the latest event,
    /// so a backdated one is recorded and may leave the status alone. Giving an open lead an
    /// active or closed status submits it first.
    public func setStatus(applicationID: Int, status: String, on day: LocalDate? = nil, note: String = "") async throws -> ApplicationOut {
        try await client.send(API.Jobs.addStatusEvent(
            applicationId: applicationID,
            body: JobStatusChange(status: status, onDate: .ifPresent(day), note: note.isEmpty ? nil : note)))
    }

    /// Submits an open lead: date applied (today when `on` is nil) and an `applied` event.
    public func apply(leadID: Int, on day: LocalDate? = nil) async throws -> ApplicationOut {
        try await client.send(API.Jobs.applyToLead(applicationId: leadID, body: JobApplyIn(onDate: .ifPresent(day))))
    }

    /// Cuts an open lead without applying. The server keeps the reason in the history and the notes.
    public func drop(leadID: Int, reason: String) async throws -> ApplicationOut {
        try await client.send(API.Jobs.dropLead(applicationId: leadID, body: JobDropIn(reason: reason)))
    }

    /// Creates an application (or submits the one open lead with the same title; see
    /// `promotedFromLead`).
    public func createApplication(_ application: ApplicationCreate) async throws -> ApplicationCreatedOut {
        try await client.send(API.Jobs.createApplication(body: application))
    }

    /// Changes the fields set in `changes`. The status changes through `setStatus`, `apply`, `drop`.
    public func updateApplication(id: Int, _ changes: ApplicationUpdate) async throws -> ApplicationOut {
        try await client.send(API.Jobs.updateApplication(applicationId: id, body: changes))
    }

    // MARK: Contacts, interviews, events

    public func createContact(_ contact: ContactCreate) async throws -> ContactCreatedOut {
        try await client.send(API.Jobs.createContact(body: contact))
    }

    public func updateContact(id: Int, _ changes: ContactUpdate) async throws -> ContactOut {
        try await client.send(API.Jobs.updateContact(contactId: id, body: changes))
    }

    public func updateInterview(id: Int, _ changes: InterviewUpdate) async throws -> InterviewOut {
        try await client.send(API.Jobs.updateInterview(interviewId: id, body: changes))
    }

    public func updateEvent(id: Int, _ changes: JobEventUpdate) async throws -> JobEventOut {
        try await client.send(API.Jobs.updateEvent(eventId: id, body: changes))
    }
}

// MARK: - The status list

extension Array where Element == JobStatusOut {
    /// The status's label as the list names it; an unknown key (a status removed since) reads as
    /// the key itself, with its first letter capitalised.
    public func label(for key: String) -> String {
        if let status = first(where: { $0.key == key }) { return status.label }
        let words = key.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The status's kind; nil for a key the list does not have.
    public func kind(of key: String) -> JobStatusOut.Kind? {
        first { $0.key == key }?.kind
    }

    /// The statuses an application can be moved to by a status change: the active ones (the
    /// funnel's stages) then the closed ones, each in list order. Lead and dropped are set by
    /// logging, Apply and Drop.
    public var changeOptions: [JobStatusOut] {
        let sorted = self.sorted { $0.position < $1.position }
        return sorted.filter { $0.kind == .active } + sorted.filter { $0.kind == .closed }
    }
}

extension ApplicationOut {
    /// An open lead (not applied to yet), by the status list's kinds. Before the list has loaded,
    /// the reserved `lead` key decides.
    public func isOpenLead(statuses: [JobStatusOut]) -> Bool {
        if let kind = statuses.kind(of: status) { return kind == .lead }
        return status == "lead" && dateApplied == nil
    }
}

extension ApplicationCreatedOut {
    /// The created (or promoted) record as the lists show it.
    public var application: ApplicationOut {
        ApplicationOut(
            createdAt: createdAt, createdBy: createdBy, updatedAt: updatedAt, id: id, companyId: companyId,
            company: company, title: title, status: status, location: location, postingUrl: postingUrl,
            source: source, nextAction: nextAction, notes: notes, tags: tags, extra: extra,
            dateApplied: dateApplied, nextActionDue: nextActionDue, reached: reached, foundOn: foundOn)
    }
}

// MARK: - Identity

// The records carry their own ids; lists and tables key on them.
extension ApplicationOut: Identifiable {}
extension ContactOut: Identifiable {}
extension InterviewOut: Identifiable {}
extension JobEventOut: Identifiable {}
extension StatusEventOut: Identifiable {}
extension CompanyRowOut: Identifiable {}
