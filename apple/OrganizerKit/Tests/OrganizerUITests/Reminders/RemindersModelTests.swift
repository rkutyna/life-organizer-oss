import Foundation
import OrganizerAPI
import OrganizerCore
import Testing

@testable import OrganizerUI

/// The Reminders screen's pure parts: scopes, sections and their order, list groups, what quick-add
/// sends to a list, and the edit sheet's PATCH.
@Suite("Reminders model")
struct RemindersModelTests {
    static let today = LocalDate("2026-11-16")!

    nonisolated static func reminder(
        _ id: Int, _ title: String, list: String = "home", due: String? = nil, time: String? = nil,
        priority: Int? = nil, completed: Bool = false, completedAt: Date? = nil,
        state: ReminderSyncOut.State = .synced, source: ReminderOut.Source = .apple, accountID: Int? = nil,
        failedOp: Int? = nil
    ) -> ReminderOut {
        let ops = failedOp.map { opID in
            [ReminderOpOut(id: opID, reminderId: id, kind: .update, applier: .helper, fields: [:], state: .failed,
                           conflicts: [], createdAt: Date(timeIntervalSince1970: 1_790_000_000), createdBy: "me",
                           error: "The list is read-only")]
        } ?? []
        return ReminderOut(
            id: id, source: source, title: title, notes: "", completed: completed, inProvider: true,
            sync: ReminderSyncOut(state: state, pendingFields: [], pendingOps: ops,
                                  error: failedOp == nil ? nil : "The list is read-only"),
            accountId: accountID, listId: list, listTitle: list.capitalized, listColor: "#FF9500",
            dueDate: due.flatMap(LocalDate.init), dueTime: time.flatMap(LocalTime.init), priority: priority,
            completedAt: completedAt
        )
    }

    nonisolated static func list(
        _ id: String, _ title: String, source: ReminderListOut.Source = .apple, accountID: Int? = nil,
        account: String = "iCloud", writable: Bool = true, isDefault: Bool = false, open: Int = 0
    ) -> ReminderListOut {
        let google = source == .google
        return ReminderListOut(
            id: id, title: title, source: source, account: account, writable: writable, isDefault: isDefault,
            supportsTime: !google, supportsPriority: !google, openCount: open, color: "#34C759", accountId: accountID)
    }

    static let rows: [ReminderOut] = [
        reminder(1, "Undated b", list: "work"),
        reminder(2, "Overdue", due: "2026-11-14"),
        reminder(3, "Today timed", due: "2026-11-16", time: "09:00"),
        reminder(4, "Today all-day", due: "2026-11-16"),
        reminder(5, "Thursday", list: "work", due: "2026-11-19"),
        reminder(6, "Tomorrow", due: "2026-11-17", priority: 1),
        reminder(7, "Done old", completed: true, completedAt: Date(timeIntervalSince1970: 1_000)),
        reminder(8, "Done new", completed: true, completedAt: Date(timeIntervalSince1970: 2_000)),
        reminder(9, "Undated a", priority: 2),
        reminder(10, "Done overdue", due: "2026-11-01", completed: true),
    ]

    // MARK: Scopes and sections

    @Test func scopeRoundTripsThroughStorage() {
        for scope in [RemindersScope.today, .upcoming, .all, .list("a:b")] {
            #expect(RemindersScope(storageKey: scope.storageKey) == scope)
        }
        #expect(RemindersScope(storageKey: "list:") == nil)
        #expect(RemindersScope(storageKey: "nonsense") == nil)
    }

    @Test func todayShowsOverdueThenToday() {
        let sections = RemindersSections.make(Self.rows, scope: .today, today: Self.today)
        #expect(sections.map(\.title) == ["Overdue", "Today"])
        #expect(sections[0].reminders.map(\.id) == [2])
        // All-day before timed, as the server orders them.
        #expect(sections[1].reminders.map(\.id) == [4, 3])
    }

    @Test func upcomingGroupsByDay() {
        let sections = RemindersSections.make(Self.rows, scope: .upcoming, today: Self.today)
        #expect(sections.map(\.id) == ["day:2026-11-17", "day:2026-11-19"])
        #expect(sections.map { $0.reminders.map(\.id) } == [[6], [5]])
    }

    @Test func allSplitsByDueDateThenCompletedNewestFirst() {
        let sections = RemindersSections.make(Self.rows, scope: .all, today: Self.today)
        #expect(sections.map(\.kind) == [.overdue, .today, .upcoming, .undated, .completed])
        // Undated: priority before none, then title.
        #expect(sections[3].reminders.map(\.id) == [9, 1])
        #expect(sections[4].reminders.map(\.id) == [8, 7, 10])
        #expect(sections[4].isCompleted)
    }

    @Test func aListShowsOnlyItsReminders() {
        let sections = RemindersSections.make(Self.rows, scope: .list("work"), today: Self.today)
        #expect(sections.flatMap(\.reminders).map(\.id).sorted() == [1, 5])
    }

    @Test func openCountsLeaveOutCompleted() {
        #expect(RemindersSections.openCount(Self.rows, scope: .all, today: Self.today) == 7)
        #expect(RemindersSections.openCount(Self.rows, scope: .today, today: Self.today) == 3)
        #expect(RemindersSections.openCount(Self.rows, scope: .upcoming, today: Self.today) == 2)
        #expect(RemindersSections.openCount(Self.rows, scope: .list("home"), today: Self.today) == 5)
    }

    @Test func listsGroupByAccount() {
        let groups = RemindersListGroup.groups([
            Self.list("home", "Home"),
            Self.list("g1", "My Tasks", source: .google, accountID: 3, account: "jane@example.com"),
            Self.list("work", "Work"),
            Self.list("g2", "Errands", source: .google, accountID: 3, account: "jane@example.com"),
        ])
        #expect(groups.map(\.title) == ["Apple Reminders · iCloud", "Google Tasks · jane@example.com"])
        #expect(groups.map { $0.lists.map(\.id) } == [["home", "work"], ["g1", "g2"]])
    }

    // MARK: Quick-add

    @Test func googleListDropsTimeAndPriority() throws {
        let parsed = QuickAdd(title: "Call Acme", dueDate: LocalDate("2026-11-17"), dueTime: LocalTime(hour: 15, minute: 0), priority: 1)
        let plan = RemindersQuickAddPlan(parsed, list: Self.list("g1", "My Tasks", source: .google, accountID: 3))
        #expect(plan.fields.dueTime == nil)
        #expect(plan.fields.priority == nil)
        #expect(plan.dropped == ["time", "priority"])
        #expect(plan.droppedNote(provider: "Google Tasks") == "Google Tasks keeps no time or priority; it is left out")

        let body = try JSONSerialization.jsonObject(with: APIJSON.encoder().encode(plan.request(listID: "g1"))) as? [String: Any]
        #expect(body?["due_date"] as? String == "2026-11-17")
        #expect(body?["due_time"] == nil)
        #expect(body?["priority"] == nil)
        #expect(body?["list_id"] as? String == "g1")
    }

    @Test func appleListKeepsEverything() {
        let parsed = QuickAdd(title: "Call Acme", dueDate: LocalDate("2026-11-17"), dueTime: LocalTime(hour: 15, minute: 0), priority: 2)
        let plan = RemindersQuickAddPlan(parsed, list: Self.list("home", "Home"))
        #expect(plan.fields == parsed)
        #expect(plan.dropped.isEmpty)
        #expect(plan.droppedNote(provider: "Apple Reminders") == nil)
        #expect(plan.hasPreview)
        #expect(!RemindersQuickAddPlan(QuickAdd(title: "Plain"), list: nil).hasPreview)
    }

    @Test func targetPrefersTheViewedListThenTheRememberedOneThenTheDefault() {
        let lists = [
            Self.list("a", "A"), Self.list("b", "B", isDefault: true),
            Self.list("ro", "Shared", writable: false), Self.list("c", "C"),
        ]
        #expect(RemindersTarget.resolve(lists, viewing: "c", remembered: "a")?.id == "c")
        #expect(RemindersTarget.resolve(lists, viewing: "ro", remembered: "a")?.id == "a")
        #expect(RemindersTarget.resolve(lists, viewing: nil, remembered: "gone")?.id == "b")
        #expect(RemindersTarget.resolve(lists, viewing: nil, remembered: "")?.id == "b")
        #expect(RemindersTarget.resolve([Self.list("ro", "Shared", writable: false)], viewing: nil, remembered: nil) == nil)
    }

    // MARK: Edit draft

    @Test func draftSendsOnlyWhatChanged() {
        let reminder = Self.reminder(3, "Call Acme", due: "2026-11-16", time: "09:00", priority: 2)
        let original = RemindersDraft(reminder)
        #expect(original.changes(from: original, supportsTime: true, supportsPriority: true) == ReminderUpdate())

        var draft = original
        draft.title = "  Call Acme back "
        draft.priority = nil
        let changes = draft.changes(from: original, supportsTime: true, supportsPriority: true)
        #expect(changes.title == .value("Call Acme back"))
        #expect(changes.priority == .null)
        #expect(changes.dueDate == .omitted)
        #expect(changes.notes == .omitted)
        #expect(changes.listId == .omitted)
    }

    @Test func clearingTheDateSendsNullAndNoTime() {
        let reminder = Self.reminder(3, "Call Acme", due: "2026-11-16", time: "09:00")
        let original = RemindersDraft(reminder)
        var draft = original
        draft.hasDate = false
        let changes = draft.changes(from: original, supportsTime: true, supportsPriority: true)
        #expect(changes.dueDate == .null)
        #expect(changes.dueTime == .omitted)
    }

    @Test func changingTheTimeSendsTheDateWithIt() {
        let reminder = Self.reminder(3, "Call Acme", due: "2026-11-16")
        let original = RemindersDraft(reminder)
        var draft = original
        draft.hasTime = true
        draft.time = LocalTime(hour: 14, minute: 30).date(on: Self.today)
        let changes = draft.changes(from: original, supportsTime: true, supportsPriority: true)
        #expect(changes.dueDate == .value(Self.today))
        #expect(changes.dueTime == .value(LocalTime(hour: 14, minute: 30)))
    }

    @Test func aGoogleListNeverGetsATimeOrPriority() {
        let reminder = Self.reminder(3, "Call Acme", due: "2026-11-16", source: .google, accountID: 3)
        let original = RemindersDraft(reminder)
        var draft = original
        draft.hasTime = true
        draft.priority = 1
        draft.date = LocalDate("2026-11-18")!.date()
        let changes = draft.changes(from: original, supportsTime: false, supportsPriority: false)
        #expect(changes.dueDate == .value(LocalDate("2026-11-18")!))
        #expect(changes.dueTime == .omitted)
        #expect(changes.priority == .omitted)
    }

    @Test func movingListsSendsTheListID() {
        let original = RemindersDraft(Self.reminder(3, "Call Acme"))
        var draft = original
        draft.listID = "work"
        #expect(draft.changes(from: original, supportsTime: true, supportsPriority: true).listId == .value("work"))
    }

    // MARK: Sync summary

    @Test func summaryNamesTheWorstState() {
        func status(pending: Int = 0, failed: Int = 0, waiting: Bool = false) -> ReminderStatusOut {
            ReminderStatusOut(
                helper: SourceStatusOut(source: "reminders", label: "Mac helper", state: .ok, staleAfterSeconds: 2700),
                google: [], helperPolling: false, pendingOps: pending, failedOps: failed, waitingForDevice: waiting)
        }
        #expect(RemindersSyncSummary(status()).title == "Up to date")
        #expect(RemindersSyncSummary(status(pending: 2)).title == "Syncing 2 changes")
        #expect(RemindersSyncSummary(status(pending: 2, waiting: true)).tone == .waiting)
        #expect(RemindersSyncSummary(status(pending: 1, failed: 1, waiting: true)).title == "1 change failed")
        #expect(RemindersSyncSummary.queueLine(status()) == nil)
        #expect(RemindersSyncSummary.queueLine(status(pending: 1, failed: 2)) == "1 pending · 2 failed")
        #expect(RemindersSyncSummary.helperLine(status()) == "The Mac helper has not checked for changes yet.")
    }
}
