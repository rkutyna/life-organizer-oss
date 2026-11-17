import Foundation
import Observation
import OrganizerAPI
import OrganizerCore

/// The Jobs screen's state: the status list, the pipeline, one read per list section (with its
/// filters), the reads behind the record screens, and where the screen is (section and stack).
///
/// - Every read is a `Resource`: it starts from the cached copy, refreshes, keeps the last good one.
/// - A filter (search, status, upcoming only) is part of its list's request, so changing it
///   replaces that list's `Resource`; the screen's `.task(id: readKey(section))` loads it.
/// - Edits are optimistic: every copy of the record changes at once and is put back if the
///   server refuses. Status changes, Apply and Drop then refetch what they move (lists, pipeline,
///   history), since the server derives the status and `reached`.
/// - Statuses come from `/api/jobs/statuses` (configurable); nothing here names one.
@MainActor
@Observable
final class JobsStore {
    let statuses: Resource<[JobStatusOut]>
    let pipeline: Resource<PipelineOut>
    /// For the company pickers, loaded when a sheet first needs it.
    let companies: Resource<[CompanyRowOut]>
    private(set) var applications: Resource<[ApplicationOut]>
    private(set) var leads: Resource<[ApplicationOut]>
    private(set) var contacts: Resource<[ContactOut]>
    private(set) var interviews: Resource<[InterviewOut]>
    private(set) var events: Resource<[JobEventOut]>

    /// The section on show. A new section starts with an empty stack.
    var section: JobsSection = .pipeline {
        didSet { if section != oldValue { path = [] } }
    }

    /// The records pushed on the section.
    var path: [JobsRoute] = []

    var notice: Notice?

    /// The sheet on show (a status change, Apply, Drop, an edit, an add), from any view.
    var sheet: JobsSheet?

    // Filters (part of each list's request).
    private(set) var applicationSearch = ""
    private(set) var applicationStatus: String?
    private(set) var includeDroppedLeads = false
    private(set) var contactSearch = ""
    private(set) var upcomingInterviewsOnly = false
    private(set) var upcomingEventsOnly = false

    @ObservationIgnored let client: OrganizerClient
    @ObservationIgnored private let today: () -> LocalDate
    // Caches of the record reads; the Resources inside are observed themselves.
    @ObservationIgnored private var applicationDetails: [Int: JobsApplicationDetail] = [:]
    @ObservationIgnored private var contactReads: [Int: Resource<ContactOut>] = [:]
    @ObservationIgnored private var interviewReads: [Int: Resource<InterviewOut>] = [:]
    @ObservationIgnored private var eventReads: [Int: Resource<JobEventOut>] = [:]

    init(client: OrganizerClient, today: @escaping () -> LocalDate = { LocalDate.today() }) {
        self.client = client
        self.today = today
        statuses = Resource(API.Jobs.listStatuses(), client: client)
        pipeline = Resource(API.Jobs.getPipeline(), client: client)
        companies = Resource(API.Jobs.listCompanies(), client: client)
        applications = Resource(Self.applicationsEndpoint(search: "", status: nil), client: client)
        leads = Resource(API.Jobs.listLeads(), client: client)
        contacts = Resource(API.Jobs.listContacts(), client: client)
        interviews = Resource(API.Jobs.listInterviews(), client: client)
        events = Resource(API.Jobs.listEvents(), client: client)
    }

    // MARK: - Navigation

    /// Opens a location (a deep link): its section, its record on top, its filter.
    func go(to location: JobsLocation) {
        section = location.section
        if location.section == .applications, location.route == nil {
            setApplicationFilter(search: applicationSearch, status: location.status)
        }
        path = location.route.map { [$0] } ?? []
    }

    func open(_ route: JobsRoute) {
        path.append(route)
    }

    /// The pipeline's status rows open the applications list filtered to that status.
    func showApplications(status: String?) {
        section = .applications
        setApplicationFilter(search: "", status: status)
    }

    // MARK: - Filters

    private static func applicationsEndpoint(search: String, status: String?) -> Endpoint<[ApplicationOut]> {
        let query = search.trimmingCharacters(in: .whitespaces)
        return API.Jobs.listApplications(status: status.map { [$0] }, q: query.isEmpty ? nil : query)
    }

    func setApplicationFilter(search: String, status: String?) {
        guard search != applicationSearch || status != applicationStatus else { return }
        applicationSearch = search
        applicationStatus = status
        applications = Resource(Self.applicationsEndpoint(search: search, status: status), client: client)
    }

    func setContactSearch(_ search: String) {
        guard search != contactSearch else { return }
        contactSearch = search
        let query = search.trimmingCharacters(in: .whitespaces)
        contacts = Resource(API.Jobs.listContacts(q: query.isEmpty ? nil : query), client: client)
    }

    func setIncludeDroppedLeads(_ include: Bool) {
        guard include != includeDroppedLeads else { return }
        includeDroppedLeads = include
        leads = Resource(API.Jobs.listLeads(includeDropped: include ? true : nil), client: client)
    }

    func setUpcomingInterviewsOnly(_ upcoming: Bool) {
        guard upcoming != upcomingInterviewsOnly else { return }
        upcomingInterviewsOnly = upcoming
        interviews = Resource(API.Jobs.listInterviews(upcoming: upcoming ? true : nil), client: client)
    }

    func setUpcomingEventsOnly(_ upcoming: Bool) {
        guard upcoming != upcomingEventsOnly else { return }
        upcomingEventsOnly = upcoming
        events = Resource(API.Jobs.listEvents(start: upcoming ? today() : nil), client: client)
    }

    // MARK: - Loading

    /// Runs when the screen opens: the status list (labels, kinds, the change menu) and the
    /// pipeline (the sidebar's counts).
    func prepare() async {
        async let statuses: Void = self.statuses.refreshIfStale(maxAge: 300)
        async let pipeline: Void = self.pipeline.refreshIfStale(maxAge: 60)
        _ = await (statuses, pipeline)
    }

    /// Identifies a section's current request, so the view reloads when a filter changes it.
    func readKey(_ section: JobsSection) -> String {
        switch section {
        case .pipeline: client.cacheKey(pipeline.endpoint)
        case .applications: client.cacheKey(applications.endpoint)
        case .leads: client.cacheKey(leads.endpoint)
        case .contacts: client.cacheKey(contacts.endpoint)
        case .interviews: client.cacheKey(interviews.endpoint)
        case .events: client.cacheKey(events.endpoint)
        }
    }

    /// The section's list, unless a copy younger than a minute is on screen.
    func load(_ section: JobsSection) async {
        switch section {
        case .pipeline: await pipeline.refreshIfStale(maxAge: 60)
        case .applications: await applications.refreshIfStale(maxAge: 60)
        case .leads: await leads.refreshIfStale(maxAge: 60)
        case .contacts: await contacts.refreshIfStale(maxAge: 60)
        case .interviews: await interviews.refreshIfStale(maxAge: 60)
        case .events: await events.refreshIfStale(maxAge: 60)
        }
    }

    /// ⌘R and Try Again: the section's list and the status list, now.
    func refresh(_ section: JobsSection) async {
        async let statuses: Void = self.statuses.refresh()
        async let list: Void = refreshList(section)
        _ = await (statuses, list)
    }

    private func refreshList(_ section: JobsSection) async {
        switch section {
        case .pipeline: await pipeline.refresh()
        case .applications: await applications.refresh()
        case .leads: await leads.refresh()
        case .contacts: await contacts.refresh()
        case .interviews: await interviews.refresh()
        case .events: await events.refresh()
        }
    }

    /// The section's status: its list first; the status list only adds to it.
    func status(_ section: JobsSection) -> LoadStatus {
        let primary: LoadStatus = switch section {
        case .pipeline: pipeline.state.status
        case .applications: applications.state.status
        case .leads: leads.state.status
        case .contacts: contacts.state.status
        case .interviews: interviews.state.status
        case .events: events.state.status
        }
        return LoadStatus(primary: primary, secondary: [statuses.state.status])
    }

    /// The sidebar's counts, from the pipeline.
    func badge(_ section: JobsSection) -> Int? {
        guard let pipeline = pipeline.value else { return nil }
        switch section {
        case .applications: return pipeline.total
        case .leads: return pipeline.leads.open
        case .interviews: return pipeline.interviews.records
        default: return nil
        }
    }

    // MARK: - Statuses

    var statusList: [JobStatusOut] { statuses.value ?? [] }

    func label(_ status: String) -> String { statusList.label(for: status) }

    func kind(_ status: String) -> JobStatusOut.Kind? { statusList.kind(of: status) }

    func isOpenLead(_ application: ApplicationOut) -> Bool { application.isOpenLead(statuses: statusList) }

    // MARK: - Record reads

    func applicationDetail(_ id: Int) -> JobsApplicationDetail {
        if let existing = applicationDetails[id] { return existing }
        let created = JobsApplicationDetail(id: id, client: client)
        applicationDetails[id] = created
        return created
    }

    /// The application as last fetched, else the lists' copy (so a record opens with its data).
    func application(_ id: Int) -> ApplicationOut? {
        applicationDetails[id]?.application.value
            ?? applications.value?.first { $0.id == id }
            ?? leads.value?.first { $0.id == id }
    }

    func contactRead(_ id: Int) -> Resource<ContactOut> {
        if let existing = contactReads[id] { return existing }
        let created = Resource(API.Jobs.getContact(contactId: id), client: client)
        contactReads[id] = created
        return created
    }

    func contact(_ id: Int) -> ContactOut? {
        contactRead(id).value ?? contacts.value?.first { $0.id == id }
    }

    func interviewRead(_ id: Int) -> Resource<InterviewOut> {
        if let existing = interviewReads[id] { return existing }
        let created = Resource(API.Jobs.getInterview(interviewId: id), client: client)
        interviewReads[id] = created
        return created
    }

    func interview(_ id: Int) -> InterviewOut? {
        interviewRead(id).value ?? interviews.value?.first { $0.id == id }
    }

    func eventRead(_ id: Int) -> Resource<JobEventOut> {
        if let existing = eventReads[id] { return existing }
        let created = Resource(API.Jobs.getEvent(eventId: id), client: client)
        eventReads[id] = created
        return created
    }

    func event(_ id: Int) -> JobEventOut? {
        eventRead(id).value ?? events.value?.first { $0.id == id }
    }

    /// A record screen's status: a copy from a list counts as something to show.
    func recordStatus<Value>(_ read: Resource<Value>, hasCopy: Bool) -> LoadStatus {
        var status = read.state.status
        status.hasValue = status.hasValue || hasCopy
        return status
    }

    // MARK: - Status changes, Apply, Drop

    /// Appends a status event. The status shows at once and is put back if the server refuses;
    /// then the lists, the pipeline and the history are fetched again (the server derives the
    /// status and how far the application got).
    func changeStatus(_ id: Int, to status: String, on day: LocalDate? = nil, note: String = "") async throws {
        let undo = modifyApplication(id) { $0.status = status }
        do {
            let saved = try await client.jobs.setStatus(applicationID: id, status: status, on: day, note: note)
            replaceApplication(saved)
        } catch {
            undo()
            throw error
        }
        await refreshAfterMove(id)
    }

    /// A status change from a menu (today, no note); a refusal shows as an alert.
    func quickChangeStatus(_ id: Int, to status: String) async {
        do {
            try await changeStatus(id, to: status)
        } catch {
            notice = .failure("Couldn't change the status", error)
        }
    }

    /// Submits an open lead on `day` (today when nil).
    func apply(leadID: Int, on day: LocalDate?) async throws {
        let saved = try await client.jobs.apply(leadID: leadID, on: day)
        replaceApplication(saved)
        notice = .info("Applied: \(saved.title) at \(saved.company)")
        await refreshAfterMove(leadID)
    }

    /// Cuts an open lead without applying.
    func drop(leadID: Int, reason: String) async throws {
        let saved = try await client.jobs.drop(leadID: leadID, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
        replaceApplication(saved)
        notice = .info("Dropped: \(saved.title)")
        await refreshAfterMove(leadID)
    }

    private func refreshAfterMove(_ id: Int) async {
        let detail = applicationDetails[id]
        async let lists: Void = refreshLoaded([applications, leads])
        async let pipeline: Void = self.pipeline.refresh()
        async let history: Void? = detail?.history.refresh()
        _ = await (lists, pipeline, history)
    }

    private func refreshLoaded(_ reads: [Resource<[ApplicationOut]>]) async {
        await withTaskGroup(of: Void.self) { group in
            for read in reads where read.value != nil {
                group.addTask { await read.refresh() }
            }
        }
    }

    // MARK: - Edits

    func updateApplication(_ original: ApplicationOut, with draft: JobsApplicationDraft) async throws {
        let changes = draft.update(from: original)
        guard changes != ApplicationUpdate() else { return }
        let companyName = companies.value?.first { $0.id == draft.companyID }?.name
        let shown = draft.applied(to: original, companyName: companyName)
        let undo = modifyApplication(original.id) { $0 = shown }
        do {
            replaceApplication(try await client.jobs.updateApplication(id: original.id, changes))
        } catch {
            undo()
            throw error
        }
        if changes.companyId.value != nil {
            await applicationDetails[original.id]?.loadContacts(force: true)
        }
    }

    func updateContact(_ original: ContactOut, with draft: JobsContactDraft) async throws {
        let changes = draft.update(from: original)
        guard changes != ContactUpdate() else { return }
        let companyName = companies.value?.first { $0.id == draft.companyID }?.name
        let shown = draft.applied(to: original, companyName: companyName)
        let undo = modifyContact(original.id) { $0 = shown }
        do {
            let saved = try await client.jobs.updateContact(id: original.id, changes)
            _ = modifyContact(original.id) { $0 = saved }
        } catch {
            undo()
            throw error
        }
    }

    func updateInterview(_ original: InterviewOut, with draft: JobsInterviewDraft) async throws {
        let changes = draft.update(from: original)
        guard changes != InterviewUpdate() else { return }
        let shown = draft.applied(to: original)
        let undo = modifyInterview(original.id, applicationID: original.applicationId) { $0 = shown }
        do {
            let saved = try await client.jobs.updateInterview(id: original.id, changes)
            _ = modifyInterview(original.id, applicationID: original.applicationId) { $0 = saved }
        } catch {
            undo()
            throw error
        }
    }

    func updateEvent(_ original: JobEventOut, with draft: JobsEventDraft) async throws {
        let changes = draft.update(from: original)
        guard changes != JobEventUpdate() else { return }
        let shown = draft.applied(to: original)
        let undo = modifyEvent(original.id) { $0 = shown }
        do {
            let saved = try await client.jobs.updateEvent(id: original.id, changes)
            _ = modifyEvent(original.id) { $0 = saved }
        } catch {
            undo()
            throw error
        }
    }

    // MARK: - Creating

    /// Adds an application and returns its id. The server may submit a matching open lead
    /// instead (said in the banner) or create its company.
    func createApplication(_ draft: JobsApplicationDraft) async throws -> Int {
        let created = try await client.jobs.createApplication(draft.create())
        if created.promotedFromLead == true {
            notice = .info("Submitted the open lead “\(created.title)” at \(created.company)")
        } else if let candidates = created.leadCandidates, !candidates.isEmpty {
            notice = .info("Added. \(candidates.count) open leads at \(created.company) have this title; none was submitted")
        } else {
            notice = .info("Added \(created.title) at \(created.company)")
        }
        // The new record opens with what the server returned (`restore` sets a value even when
        // the read has none yet).
        let read = applicationDetail(created.id).application
        if read.value == nil { read.restore(created.application) } else { read.modify { $0 = created.application } }
        async let lists: Void = refreshLoaded([applications, leads])
        async let pipeline: Void = self.pipeline.refresh()
        async let companies: Void = refreshCompaniesIfCreated(created.companyCreated == true)
        _ = await (lists, pipeline, companies)
        return created.id
    }

    /// Adds a contact and returns its id.
    func createContact(_ draft: JobsContactDraft) async throws -> Int {
        let created = try await client.jobs.createContact(draft.create())
        notice = .info("Added \(created.name)")
        async let contacts: Void = self.contacts.refresh()
        async let companies: Void = refreshCompaniesIfCreated(created.companyCreated == true)
        _ = await (contacts, companies)
        return created.id
    }

    private func refreshCompaniesIfCreated(_ created: Bool) async {
        if created || companies.value == nil { await companies.refresh() }
    }

    func loadCompanies() async {
        await companies.refreshIfStale(maxAge: 300)
    }

    // MARK: - Copies

    /// Changes the application in every copy (both lists, its record read) and returns a closure
    /// that puts them all back.
    private func modifyApplication(_ id: Int, _ change: (inout ApplicationOut) -> Void) -> () -> Void {
        let lists = [applications, leads]
        let before = lists.map { $0.modify { $0.mutate(id: id, change) } }
        let detail = applicationDetails[id]?.application
        let detailBefore = detail?.modify(change)
        return {
            for (read, value) in zip(lists, before) { read.restore(value) }
            if let detail { detail.restore(detailBefore) }
        }
    }

    private func replaceApplication(_ saved: ApplicationOut) {
        _ = modifyApplication(saved.id) { $0 = saved }
    }

    private func modifyContact(_ id: Int, _ change: (inout ContactOut) -> Void) -> () -> Void {
        var reads = [contacts]
        reads += applicationDetails.values.compactMap(\.contacts)
        let before = reads.map { $0.modify { $0.mutate(id: id, change) } }
        let single = contactReads[id]
        let singleBefore = single?.modify(change)
        return {
            for (read, value) in zip(reads, before) { read.restore(value) }
            if let single { single.restore(singleBefore) }
        }
    }

    private func modifyInterview(_ id: Int, applicationID: Int, _ change: (inout InterviewOut) -> Void) -> () -> Void {
        var reads = [interviews]
        if let detail = applicationDetails[applicationID] { reads.append(detail.interviews) }
        let before = reads.map { $0.modify { $0.mutate(id: id, change) } }
        let single = interviewReads[id]
        let singleBefore = single?.modify(change)
        return {
            for (read, value) in zip(reads, before) { read.restore(value) }
            if let single { single.restore(singleBefore) }
        }
    }

    private func modifyEvent(_ id: Int, _ change: (inout JobEventOut) -> Void) -> () -> Void {
        let before = events.modify { $0.mutate(id: id, change) }
        let single = eventReads[id]
        let singleBefore = single?.modify(change)
        let list = events
        return {
            list.restore(before)
            if let single { single.restore(singleBefore) }
        }
    }
}

/// The reads behind one application's screen: the record, its status history, its interviews,
/// and the contacts at its company (read once the company is known).
@MainActor
@Observable
final class JobsApplicationDetail {
    let id: Int
    let application: Resource<ApplicationOut>
    let history: Resource<[StatusEventOut]>
    let interviews: Resource<[InterviewOut]>
    private(set) var contacts: Resource<[ContactOut]>?

    @ObservationIgnored private let client: OrganizerClient
    @ObservationIgnored private var contactsCompanyID: Int?

    init(id: Int, client: OrganizerClient) {
        self.id = id
        self.client = client
        application = Resource(API.Jobs.getApplication(applicationId: id), client: client)
        history = Resource(API.Jobs.listStatusEvents(applicationId: id), client: client)
        interviews = Resource(API.Jobs.listInterviews(applicationId: id), client: client)
    }

    /// Everything, fetched now (`force`) or unless a copy younger than 30 seconds is on screen.
    func load(force: Bool = false) async {
        async let application: Void = Self.fetch(self.application, force: force)
        async let history: Void = Self.fetch(self.history, force: force)
        async let interviews: Void = Self.fetch(self.interviews, force: force)
        _ = await (application, history, interviews)
        await loadContacts(force: force)
    }

    /// The contacts at the application's company; a new read when the company changed.
    func loadContacts(force: Bool = false) async {
        guard let companyID = application.value?.companyId else { return }
        if contacts == nil || contactsCompanyID != companyID {
            contacts = Resource(API.Jobs.listContacts(companyId: companyID), client: client)
            contactsCompanyID = companyID
        }
        if let contacts { await Self.fetch(contacts, force: force) }
    }

    private static func fetch<Value>(_ read: Resource<Value>, force: Bool) async {
        if force {
            await read.refresh()
        } else {
            await read.refreshIfStale()
        }
    }
}

extension Array {
    /// Changes the element with `id`, if any.
    fileprivate mutating func mutate<ID: Equatable>(id: ID, _ change: (inout Element) -> Void) where Element: Identifiable, Element.ID == ID {
        if let index = firstIndex(where: { $0.id == id }) { change(&self[index]) }
    }
}
