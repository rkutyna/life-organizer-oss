import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// Fictional tracker records (Acme, Jane Doe, example.com) for the Jobs tests.
enum JobsFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    static let statuses: [JobStatusOut] = [
        JobStatusOut(key: "lead", label: "Lead", kind: .lead, position: 0, reserved: true),
        JobStatusOut(key: "applied", label: "Applied", kind: .active, position: 1, reserved: true),
        JobStatusOut(key: "chat", label: "Coffee chat", kind: .active, position: 2, reserved: false),
        JobStatusOut(key: "rejected", label: "Rejected", kind: .closed, position: 3, reserved: false),
        JobStatusOut(key: "dropped", label: "Dropped lead", kind: .dropped, position: 4, reserved: true),
    ]

    static func application(_ id: Int, _ title: String = "Engineer", status: String = "applied",
                            company: String = "Acme", companyID: Int = 1, applied: String? = "2026-11-02") -> ApplicationOut {
        ApplicationOut(
            createdAt: epoch, createdBy: "system", updatedAt: epoch, id: id, companyId: companyID, company: company,
            title: title, status: status, location: "", postingUrl: "", source: "", nextAction: "", notes: "",
            tags: [], extra: [:], dateApplied: applied.flatMap(LocalDate.init), reached: status == "lead" ? nil : status)
    }

    static func contact(_ id: Int, _ name: String = "Jane Doe", companyID: Int? = 1) -> ContactOut {
        ContactOut(
            createdAt: epoch, createdBy: "system", updatedAt: epoch, id: id, name: name, role: "Recruiter",
            email: "jane@example.com", profileUrl: "", nextAction: "Follow up", notes: "", tags: [],
            companyId: companyID, company: companyID == nil ? nil : "Acme")
    }

    static func interview(_ id: Int, applicationID: Int = 1) -> InterviewOut {
        InterviewOut(
            createdAt: epoch, createdBy: "system", updatedAt: epoch, id: id, applicationId: applicationID,
            companyId: 1, company: "Acme", applicationTitle: "Engineer", stage: "Screen", location: "",
            interviewer: "Jane Doe", notes: "", onDate: LocalDate("2026-11-18"), startTime: LocalTime(hour: 14, minute: 0),
            durationMinutes: 45)
    }

    static func event(_ id: Int) -> JobEventOut {
        JobEventOut(
            createdAt: epoch, createdBy: "system", updatedAt: epoch, id: id, name: "City Career Fair", kind: "fair",
            onDate: LocalDate("2026-11-19")!, location: "Hall B", url: "", notes: "", tags: [],
            startTime: LocalTime(hour: 17, minute: 0), endTime: LocalTime(hour: 19, minute: 30))
    }

    static let pipeline = PipelineOut(
        total: 2,
        byStatus: [PipelineStatusCount(status: "applied", label: "Applied", kind: "active", count: 2)],
        reached: [PipelineStageCount(status: "applied", label: "Applied", count: 2)],
        leads: PipelineLeads(open: 1, dropped: 0),
        interviews: PipelineInterviews(applications: 1, records: 1))
}

@Suite("Jobs store")
@MainActor
struct JobsStoreTests {
    let server = StubServer()

    init() {
        server.respond(.get, "/api/jobs/statuses", value: JobsFixtures.statuses)
        server.respond(.get, "/api/jobs/pipeline", value: JobsFixtures.pipeline)
        server.respond(.get, "/api/jobs/applications", value: [JobsFixtures.application(1), JobsFixtures.application(2, "Designer")])
        server.respond(.get, "/api/jobs/leads", value: [JobsFixtures.application(3, "Advocate", status: "lead", applied: nil)])
        server.respond(.get, "/api/jobs/contacts", value: [JobsFixtures.contact(1)])
        server.respond(.get, "/api/jobs/interviews", value: [JobsFixtures.interview(1)])
        server.respond(.get, "/api/jobs/events", value: [JobsFixtures.event(1)])
    }

    func makeStore() -> JobsStore {
        JobsStore(client: server.client(), today: { LocalDate("2026-11-16")! })
    }

    // MARK: Loading and filters

    @Test func loadsTheStatusListPipelineAndASection() async {
        let store = makeStore()
        await store.prepare()
        await store.load(.applications)
        #expect(store.label("chat") == "Coffee chat")
        #expect(store.badge(.applications) == 2)
        #expect(store.badge(.leads) == 1)
        #expect(store.applications.value?.map(\.id) == [1, 2])
        #expect(store.status(.applications).hasValue)
    }

    @Test func filtersArePartOfTheRequest() async throws {
        let store = makeStore()
        store.setApplicationFilter(search: "acme ", status: "chat")
        await store.load(.applications)
        let query = try #require(server.requests(.get, "/api/jobs/applications").last?.query)
        #expect(query.contains("status=chat"))
        #expect(query.contains("q=acme"))

        store.setContactSearch("jane")
        await store.load(.contacts)
        #expect(server.requests(.get, "/api/jobs/contacts").last?.query == "q=jane")

        store.setIncludeDroppedLeads(true)
        await store.load(.leads)
        #expect(server.requests(.get, "/api/jobs/leads").last?.query == "include_dropped=true")

        store.setUpcomingEventsOnly(true)
        await store.load(.events)
        #expect(server.requests(.get, "/api/jobs/events").last?.query == "start=2026-11-16")

        store.setUpcomingInterviewsOnly(true)
        await store.load(.interviews)
        #expect(server.requests(.get, "/api/jobs/interviews").last?.query == "upcoming=true")
    }

    @Test func aFilterChangeChangesTheReadKey() {
        let store = makeStore()
        let before = store.readKey(.applications)
        store.setApplicationFilter(search: "", status: "rejected")
        #expect(store.readKey(.applications) != before)
    }

    // MARK: Navigation

    @Test func goingToALocationSetsTheSectionStackAndFilter() {
        let store = makeStore()
        store.path = [.contact(1)]
        store.go(to: JobsLocation(section: .applications, route: .application(12)))
        #expect(store.section == .applications)
        #expect(store.path == [.application(12)])

        store.go(to: JobsLocation(section: .applications, status: "chat"))
        #expect(store.path.isEmpty)
        #expect(store.applicationStatus == "chat")

        store.go(to: JobsLocation(section: .events, route: .event(4)))
        #expect(store.section == .events)
        #expect(store.path == [.event(4)])
    }

    @Test func anotherSectionStartsAnEmptyStack() {
        let store = makeStore()
        store.open(.application(1))
        store.section = .contacts
        #expect(store.path.isEmpty)
    }

    // MARK: Status changes

    @Test func changingTheStatusPostsTheEventAndShowsTheServersResult() async throws {
        let store = makeStore()
        await store.prepare()
        await store.load(.applications)
        var saved = JobsFixtures.application(1, status: "chat")
        saved.reached = "chat"
        server.respond(.post, "/api/jobs/applications/1/status", value: saved)
        server.respond(.get, "/api/jobs/applications", value: [saved, JobsFixtures.application(2, "Designer")])

        try await store.changeStatus(1, to: "chat", on: LocalDate("2026-11-15"), note: "Went well")

        let body = try #require(server.requests(.post, "/api/jobs/applications/1/status").last?.json)
        #expect(body == .object(["status": .string("chat"), "on_date": .string("2026-11-15"), "note": .string("Went well")]))
        #expect(store.applications.value?.first?.status == "chat")
        #expect(store.applications.value?.first?.reached == "chat")
        // The pipeline is fetched again (the server derives the counts).
        #expect(server.requests(.get, "/api/jobs/pipeline").count == 2)
    }

    @Test func aRefusedStatusChangePutsTheStatusBack() async {
        let store = makeStore()
        await store.load(.applications)
        server.respond(.post, "/api/jobs/applications/1/status", status: 422, json: #"{"detail": "unknown status: nope"}"#)

        await store.quickChangeStatus(1, to: "nope")

        #expect(store.applications.value?.first?.status == "applied")
        #expect(store.notice?.kind == .failure)
        #expect(store.notice?.message == "unknown status: nope")
    }

    @Test func applyAndDropSendTheirBodies() async throws {
        let store = makeStore()
        await store.load(.leads)
        server.respond(.post, "/api/jobs/applications/3/apply", value: JobsFixtures.application(3, "Advocate", status: "applied", applied: "2026-11-14"))
        try await store.apply(leadID: 3, on: LocalDate("2026-11-14"))
        #expect(server.requests(.post, "/api/jobs/applications/3/apply").last?.json == .object(["on_date": .string("2026-11-14")]))

        server.respond(.post, "/api/jobs/applications/3/drop", value: JobsFixtures.application(3, "Advocate", status: "dropped", applied: nil))
        try await store.drop(leadID: 3, reason: "  needs relocation \n")
        #expect(server.requests(.post, "/api/jobs/applications/3/drop").last?.json == .object(["reason": .string("needs relocation")]))
        #expect(store.notice?.title == "Dropped: Advocate")
    }

    @Test func aRefusedApplyThrowsTheServersMessage() async {
        let store = makeStore()
        server.respond(.post, "/api/jobs/applications/3/apply", status: 409, json: #"{"detail": "the day is before the lead was found"}"#)
        await #expect(throws: APIError.self) {
            try await store.apply(leadID: 3, on: LocalDate("2020-01-01"))
        }
        do {
            try await store.apply(leadID: 3, on: LocalDate("2020-01-01"))
        } catch {
            #expect(APIError(error).message == "the day is before the lead was found")
        }
    }

    // MARK: Edits

    @Test func editingAContactSendsOnlyWhatChanged() async throws {
        let store = makeStore()
        await store.load(.contacts)
        let original = JobsFixtures.contact(1)
        var draft = JobsContactDraft(original)
        draft.role = " Hiring Manager "
        draft.nextActionDue = LocalDate("2026-11-20")
        var saved = original
        saved.role = "Hiring Manager"
        saved.nextActionDue = LocalDate("2026-11-20")
        server.respond(.patch, "/api/jobs/contacts/1", value: saved)

        try await store.updateContact(original, with: draft)

        let body = try #require(server.requests(.patch, "/api/jobs/contacts/1").last?.json)
        #expect(body == .object(["role": .string("Hiring Manager"), "next_action_due": .string("2026-11-20")]))
        #expect(store.contacts.value?.first?.role == "Hiring Manager")
    }

    @Test func anUnchangedDraftSendsNothing() async throws {
        let store = makeStore()
        let original = JobsFixtures.event(1)
        try await store.updateEvent(original, with: JobsEventDraft(original))
        #expect(server.requests(.patch, "/api/jobs/events/1").isEmpty)
    }

    @Test func aRefusedEditPutsTheRecordBack() async {
        let store = makeStore()
        await store.load(.events)
        let original = JobsFixtures.event(1)
        var draft = JobsEventDraft(original)
        draft.name = "Renamed fair"
        server.respond(.patch, "/api/jobs/events/1", status: 422, json: #"{"detail": "the end is before the start"}"#)

        await #expect(throws: APIError.self) {
            try await store.updateEvent(original, with: draft)
        }
        #expect(store.events.value?.first?.name == "City Career Fair")
    }

    @Test func editingAnInterviewUpdatesTheListAndItsApplication() async throws {
        let store = makeStore()
        await store.load(.interviews)
        let detail = store.applicationDetail(1)
        server.respond(.get, "/api/jobs/applications/1", value: JobsFixtures.application(1))
        server.respond(.get, "/api/jobs/applications/1/status", json: "[]")
        await detail.load()
        let original = JobsFixtures.interview(1)
        var draft = JobsInterviewDraft(original)
        draft.onDate = nil
        var saved = original
        saved.onDate = nil
        saved.startTime = nil
        server.respond(.patch, "/api/jobs/interviews/1", value: saved)

        try await store.updateInterview(original, with: draft)

        let body = try #require(server.requests(.patch, "/api/jobs/interviews/1").last?.json)
        // Clearing the day clears the time with it (a time needs a day).
        #expect(body == .object(["on_date": .null, "start_time": .null]))
        #expect(store.interviews.value?.first?.onDate == nil)
        #expect(detail.interviews.value?.first?.onDate == nil)
    }

    // MARK: Creating

    @Test func addingAnApplicationByCompanyName() async throws {
        let store = makeStore()
        var draft = JobsApplicationDraft()
        draft.title = " Platform Engineer "
        draft.companyName = "Example Labs"
        draft.status = "applied"
        draft.dateApplied = LocalDate("2026-11-16")
        let created = ApplicationCreatedOut(
            createdAt: JobsFixtures.epoch, createdBy: "user", updatedAt: JobsFixtures.epoch, id: 40, companyId: 9,
            company: "Example Labs", title: "Platform Engineer", status: "applied", location: "", postingUrl: "",
            source: "", nextAction: "", notes: "", tags: [], extra: [:], dateApplied: LocalDate("2026-11-16"),
            companyCreated: true)
        server.respond(.post, "/api/jobs/applications", value: created)
        server.respond(.get, "/api/jobs/companies", json: "[]")

        let id = try await store.createApplication(draft)

        #expect(id == 40)
        let body = try #require(server.requests(.post, "/api/jobs/applications").last?.json)
        #expect(body == .object([
            "title": .string("Platform Engineer"), "company": .string("Example Labs"),
            "status": .string("applied"), "date_applied": .string("2026-11-16"),
        ]))
        #expect(store.application(40)?.title == "Platform Engineer")
        #expect(server.requests(.get, "/api/jobs/companies").count == 1)
    }

    @Test func aPromotedLeadIsSaidSo() async throws {
        let store = makeStore()
        var draft = JobsApplicationDraft()
        draft.title = "Advocate"
        draft.companyID = 1
        let created = ApplicationCreatedOut(
            createdAt: JobsFixtures.epoch, createdBy: "user", updatedAt: JobsFixtures.epoch, id: 3, companyId: 1,
            company: "Acme", title: "Advocate", status: "applied", location: "", postingUrl: "", source: "",
            nextAction: "", notes: "", tags: [], extra: [:], promotedFromLead: true)
        server.respond(.post, "/api/jobs/applications", value: created)
        server.respond(.get, "/api/jobs/companies", json: "[]")

        _ = try await store.createApplication(draft)

        #expect(server.requests(.post, "/api/jobs/applications").last?.json?["company_id"] == .number(1))
        #expect(store.notice?.title.contains("Submitted the open lead") == true)
    }

    @Test func addingAContact() async throws {
        let store = makeStore()
        var draft = JobsContactDraft()
        draft.name = "John Roe"
        draft.companyName = ""
        server.respond(.post, "/api/jobs/contacts", value: ContactCreatedOut(
            createdAt: JobsFixtures.epoch, createdBy: "user", updatedAt: JobsFixtures.epoch, id: 7, name: "John Roe",
            role: "", email: "", profileUrl: "", nextAction: "", notes: "", tags: []))
        server.respond(.get, "/api/jobs/companies", json: "[]")

        let id = try await store.createContact(draft)

        #expect(id == 7)
        #expect(server.requests(.post, "/api/jobs/contacts").last?.json == .object(["name": .string("John Roe")]))
    }

    // MARK: Record screens

    @Test func anApplicationDetailReadsTheContactsAtItsCompany() async throws {
        let store = makeStore()
        server.respond(.get, "/api/jobs/applications/1", value: JobsFixtures.application(1, companyID: 5))
        server.respond(.get, "/api/jobs/applications/1/status", json: "[]")
        let detail = store.applicationDetail(1)
        await detail.load()
        #expect(server.requests(.get, "/api/jobs/contacts").last?.query == "company_id=5")
        #expect(server.requests(.get, "/api/jobs/interviews").last?.query == "application_id=1")
        #expect(detail.contacts?.value?.count == 1)
    }

    @Test func aRecordOpensWithTheListsCopy() async {
        let store = makeStore()
        await store.load(.contacts)
        #expect(store.contact(1)?.name == "Jane Doe")
        #expect(store.recordStatus(store.contactRead(1), hasCopy: true).hasValue)
    }
}
