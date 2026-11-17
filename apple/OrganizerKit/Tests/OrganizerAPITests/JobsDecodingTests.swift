import Foundation
import OrganizerAPI
import OrganizerTestSupport
import Testing

/// The job tracker's wire formats (fictional records in the server's shape) and the status-list
/// helpers the screen relies on instead of hardcoding statuses.
@Suite("Jobs decoding")
struct JobsDecodingTests {
    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    static let statusesJSON = """
    [{"key":"lead","label":"Lead","kind":"lead","position":0,"reserved":true},
     {"key":"applied","label":"Applied","kind":"active","position":1,"reserved":true},
     {"key":"rejected","label":"Rejected","kind":"closed","position":3,"reserved":false},
     {"key":"chat","label":"Coffee chat","kind":"active","position":2,"reserved":false},
     {"key":"dropped","label":"Dropped lead","kind":"dropped","position":4,"reserved":true},
     {"key":"parked","label":"Parked","kind":"someday","position":5,"reserved":false}]
    """

    @Test func applicationDecodesWithNullsAndExtra() throws {
        let application = try Self.decode(ApplicationOut.self, """
        {"created_at":"2026-11-17T03:16:50.030271Z","created_by":"system","updated_at":"2026-11-17T03:16:50Z",
         "id":13,"company_id":1,"company":"Acme","title":"Developer Advocate","status":"lead",
         "date_applied":null,"location":"","posting_url":"https://jobs.example.com/1","source":"",
         "next_action":"","next_action_due":null,"notes":"","tags":["remote"],"extra":{"Recruiter":"Jane Doe"},
         "reached":null,"found_on":"2026-11-12"}
        """)
        #expect(application.id == 13)
        #expect(application.dateApplied == nil)
        #expect(application.foundOn == LocalDate("2026-11-12"))
        #expect(application.extra["Recruiter"] == "Jane Doe")
        #expect(application.reached == nil)
    }

    @Test func pipelineDecodes() throws {
        let pipeline = try Self.decode(PipelineOut.self, """
        {"total":3,"by_status":[{"status":"applied","label":"Applied","kind":"active","count":2},
         {"status":"rejected","label":"Rejected","kind":"closed","count":1}],
         "reached":[{"status":"applied","label":"Applied","count":3}],
         "leads":{"open":2,"dropped":1},"interviews":{"applications":1,"records":2}}
        """)
        #expect(pipeline.total == 3)
        #expect(pipeline.byStatus.map(\.count) == [2, 1])
        #expect(pipeline.reached.first?.count == 3)
        #expect(pipeline.leads.dropped == 1)
        #expect(pipeline.interviews.records == 2)
    }

    @Test func interviewAndEventTimesDecode() throws {
        let interview = try Self.decode(InterviewOut.self, """
        {"created_at":"2026-11-17T03:16:50Z","created_by":"system","updated_at":"2026-11-17T03:16:50Z",
         "id":1,"application_id":1,"company_id":1,"company":"Acme","application_title":"Engineer",
         "stage":"Onsite","on_date":"2026-11-18","start_time":"14:00:00","duration_minutes":90,
         "location":"Video call","interviewer":"Jane Doe","notes":""}
        """)
        #expect(interview.startTime == LocalTime(hour: 14, minute: 0))
        #expect(interview.durationMinutes == 90)

        let event = try Self.decode(JobEventOut.self, """
        {"created_at":"2026-11-17T03:16:50Z","created_by":"system","updated_at":"2026-11-17T03:16:50Z",
         "id":1,"name":"City Career Fair","kind":"fair","on_date":"2026-11-19","start_time":"17:00:00",
         "end_time":null,"location":"Hall B","url":"","attended":null,"notes":"","tags":[]}
        """)
        #expect(event.endTime == nil)
        #expect(event.attended == nil)
    }

    @Test func unknownStatusKindsSurvive() throws {
        let statuses = try Self.decode([JobStatusOut].self, Self.statusesJSON)
        #expect(statuses.kind(of: "parked") == .unknown("someday"))
    }

    // MARK: Status list helpers

    @Test func changeOptionsAreActiveThenClosedInListOrder() throws {
        let statuses = try Self.decode([JobStatusOut].self, Self.statusesJSON)
        #expect(statuses.changeOptions.map(\.key) == ["applied", "chat", "rejected"])
    }

    @Test func labelsComeFromTheListWithAFallback() throws {
        let statuses = try Self.decode([JobStatusOut].self, Self.statusesJSON)
        #expect(statuses.label(for: "chat") == "Coffee chat")
        #expect(statuses.label(for: "phone_screen") == "Phone screen")
        #expect(statuses.kind(of: "nope") == nil)
    }

    @Test func openLeadFollowsTheListsKinds() throws {
        let statuses = try Self.decode([JobStatusOut].self, Self.statusesJSON)
        let lead = try Self.decode(ApplicationOut.self, """
        {"created_at":"2026-11-17T03:16:50Z","created_by":"system","updated_at":"2026-11-17T03:16:50Z",
         "id":2,"company_id":1,"company":"Acme","title":"Engineer","status":"lead","date_applied":null,
         "location":"","posting_url":"","source":"","next_action":"","next_action_due":null,"notes":"",
         "tags":[],"extra":{},"reached":null,"found_on":null}
        """)
        #expect(lead.isOpenLead(statuses: statuses))
        #expect(lead.isOpenLead(statuses: []))
        var applied = lead
        applied.status = "chat"
        #expect(!applied.isOpenLead(statuses: statuses))
    }

    // MARK: Request bodies

    @Test func statusChangeLeavesOutWhatIsNotSet() throws {
        let body = try APIJSON.encoder().encode(JobStatusChange(status: "chat", onDate: .ifPresent(nil), note: nil))
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(json == .object(["status": .string("chat")]))
    }
}
