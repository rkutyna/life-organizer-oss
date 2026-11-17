import Foundation
import OrganizerAPI
import OrganizerCore
import Testing

@testable import OrganizerUI

/// The Jobs screen's pure parts: deep links, labels and the edit drafts.
@Suite("Jobs model")
struct JobsModelTests {
    // MARK: Deep links

    @Test(arguments: [
        ("lifeorganizer://jobs", JobsLocation(section: .pipeline)),
        ("lifeorganizer://jobs/applications/12", JobsLocation(section: .applications, route: .application(12))),
        ("lifeorganizer://jobs/applications?status=screen", JobsLocation(section: .applications, status: "screen")),
        ("lifeorganizer://jobs/leads", JobsLocation(section: .leads)),
        ("lifeorganizer://jobs/contacts/3", JobsLocation(section: .contacts, route: .contact(3))),
        ("lifeorganizer://jobs/interviews/2", JobsLocation(section: .interviews, route: .interview(2))),
        ("lifeorganizer://jobs/events?event=4", JobsLocation(section: .events, route: .event(4))),
        ("lifeorganizer://jobs/events", JobsLocation(section: .events)),
    ])
    func deepLinksOpenTheirPlace(url: String, expected: JobsLocation) throws {
        let link = try #require(DeepLink(URL(string: url)!))
        #expect(JobsLocation(link) == expected)
    }

    @Test(arguments: ["lifeorganizer://jobs/companies/3", "lifeorganizer://jobs/applications/abc", "lifeorganizer://jobs/import"])
    func pagesThisScreenDoesNotHaveAreIgnored(url: String) throws {
        let link = try #require(DeepLink(URL(string: url)!))
        #expect(JobsLocation(link) == nil)
    }

    @Test func theCalendarsDetailURLsRoundTrip() throws {
        // The calendar turns `/jobs/events?event=4` into a link with the same path and query.
        let link = DeepLink(module: .jobs, path: ["events"], query: ["event": "4"])
        let url = try #require(link.url)
        let read = try #require(DeepLink(url))
        #expect(JobsLocation(read)?.route == .event(4))
    }

    // MARK: Labels

    @Test func nextActionReadsWithItsDueDay() {
        let now = LocalDate("2026-11-16")!.date(in: .current).addingTimeInterval(12 * 3600)
        #expect(JobsFormat.nextAction("", due: nil, now: now) == "")
        #expect(JobsFormat.nextAction("Follow up", due: nil, now: now) == "Follow up")
        #expect(JobsFormat.nextAction("Follow up", due: LocalDate("2026-11-17"), now: now) == "Follow up · Tomorrow")
        #expect(JobsFormat.nextAction("", due: LocalDate("2026-11-16"), now: now) == "Due Today")
    }

    @Test func dueDaysAreOverdueTodayOrLater() {
        let today = LocalDate("2026-11-16")!
        #expect(JobsFormat.due(LocalDate("2026-11-15"), today: today) == .overdue)
        #expect(JobsFormat.due(today, today: today) == .today)
        #expect(JobsFormat.due(LocalDate("2026-11-30"), today: today) == .later)
        #expect(JobsFormat.due(nil, today: today) == nil)
    }

    @Test func tagsSplitOnCommas() {
        #expect(JobsFormat.splitTags(" remote, referral ,, ") == ["remote", "referral"])
        #expect(JobsFormat.splitTags("") == [])
    }

    @Test func onlyWebAddressesAreLinks() {
        #expect(JobsFormat.webURL("https://jobs.example.com/1") != nil)
        #expect(JobsFormat.webURL("Video call") == nil)
        #expect(JobsFormat.webURL("javascript:alert(1)") == nil)
    }

    @Test func interviewWhenSaysWhenItIsNotScheduled() {
        var interview = JobsFixtures.interview(1)
        interview.onDate = nil
        #expect(JobsFormat.interviewWhen(interview) == "Not scheduled")
        #expect(JobsFormat.interviewWhen(JobsFixtures.interview(1)).hasSuffix("45 min"))
    }

    // MARK: Drafts

    @Test func applicationDraftSendsOnlyWhatChanged() {
        let original = JobsFixtures.application(1)
        var draft = JobsApplicationDraft(original)
        #expect(draft.update(from: original) == ApplicationUpdate())
        draft.title = "Senior Engineer "
        draft.nextActionDue = LocalDate("2026-11-20")
        draft.tags = "referral"
        let update = draft.update(from: original)
        #expect(update.title == .value("Senior Engineer"))
        #expect(update.nextActionDue == .value(LocalDate("2026-11-20")!))
        #expect(update.tags == .value(["referral"]))
        #expect(update.location.isOmitted)
        #expect(update.companyId.isOmitted)

        let shown = draft.applied(to: original, companyName: nil)
        #expect(shown.title == "Senior Engineer")
        #expect(shown.status == original.status)
    }

    @Test func clearingADateSendsNull() {
        var original = JobsFixtures.application(1)
        original.nextActionDue = LocalDate("2026-11-20")
        var draft = JobsApplicationDraft(original)
        draft.nextActionDue = nil
        #expect(draft.update(from: original).nextActionDue == .null)
    }

    @Test func aNewApplicationNamesItsCompanyUnlessOneWasPicked() {
        var draft = JobsApplicationDraft()
        draft.title = "Engineer"
        draft.companyName = "Acme"
        #expect(draft.canCreate)
        #expect(draft.create().company == .value("Acme"))
        #expect(draft.create().companyId.isOmitted)
        draft.companyID = 1
        #expect(draft.create().company.isOmitted)
        #expect(draft.create().companyId == .value(1))
        draft.title = "  "
        #expect(!draft.canCreate)
    }

    @Test func contactDraftCanLeaveItsCompany() {
        let original = JobsFixtures.contact(1)
        var draft = JobsContactDraft(original)
        draft.companyID = nil
        #expect(draft.update(from: original).companyId == .null)
        #expect(draft.applied(to: original, companyName: nil).company == nil)
    }

    @Test func eventDraftDropsTheEndWithTheStart() {
        let original = JobsFixtures.event(1)
        var draft = JobsEventDraft(original)
        draft.startTime = nil
        let update = draft.update(from: original)
        #expect(update.startTime == .null)
        #expect(update.endTime == .null)
        #expect(draft.applied(to: original).endTime == nil)
    }

    @Test func eventDraftRefusesAnEndBeforeItsStart() {
        var draft = JobsEventDraft(JobsFixtures.event(1))
        draft.endTime = LocalTime(hour: 16, minute: 0)
        #expect(!draft.canSave)
        draft.endTime = LocalTime(hour: 18, minute: 0)
        draft.name = " "
        #expect(!draft.canSave)
    }

    @Test func interviewDurationIsFiveMinutesToADay() {
        var draft = JobsInterviewDraft(JobsFixtures.interview(1))
        draft.durationMinutes = 2
        #expect(!draft.canSave)
        draft.durationMinutes = nil
        #expect(draft.canSave)
        #expect(draft.update(from: JobsFixtures.interview(1)).durationMinutes == .null)
    }
}
