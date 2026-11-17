import Foundation
import OrganizerAPI
import OrganizerCore
import OrganizerTestSupport
import Testing

@testable import OrganizerUI

/// The Reminders store against a stub server: loading, optimistic completion and its rollback,
/// quick-add bodies, edits, Retry and Withdraw of failed ops, Sync Now, and the poll interval.
@Suite("Reminders store")
@MainActor
struct RemindersStoreTests {
    static let today = RemindersModelTests.today
    typealias M = RemindersModelTests

    let server = StubServer()

    static let rows: [ReminderOut] = [
        M.reminder(1, "Water the plants", due: "2026-11-16"),
        M.reminder(2, "Call Acme", list: "shared", due: "2026-11-15"),
        M.reminder(3, "Send the report", list: "work", failedOp: 41),
    ]
    static let lists: [ReminderListOut] = [
        M.list("home", "Home", isDefault: true, open: 1),
        M.list("work", "Work", open: 1),
        M.list("shared", "Shared", writable: false, open: 1),
    ]

    static func status(pending: Int = 0, failed: Int = 0, waiting: Bool = false) -> ReminderStatusOut {
        ReminderStatusOut(
            helper: SourceStatusOut(source: "reminders", label: "Mac helper (Apple Reminders)", state: .ok,
                                    staleAfterSeconds: 2700, lastSuccessAt: Date()),
            google: [], helperPolling: true, pendingOps: pending, failedOps: failed, waitingForDevice: waiting)
    }

    init() {
        server.respond(.get, "/api/reminders", value: Self.rows)
        server.respond(.get, "/api/reminders/lists", value: Self.lists)
        server.respond(.get, "/api/reminders/status", value: Self.status(failed: 1))
    }

    func makeStore() async -> RemindersStore {
        let store = RemindersStore(client: server.client(), today: { Self.today })
        await store.refresh()
        return store
    }

    // MARK: Loading

    @Test func loadsAllThreeReadsAndAsksForCompleted() async throws {
        let store = await makeStore()
        #expect(store.reminders.value?.count == 3)
        #expect(store.lists.value?.count == 3)
        #expect(store.status.value?.failedOps == 1)
        #expect(store.loadStatus.hasValue)
        let request = try #require(server.requests(.get, "/api/reminders").first)
        #expect(request.query == "include_completed=true")
        #expect(store.sections(for: .today).map(\.title) == ["Overdue", "Today"])
        #expect(store.openCount(for: .list("work")) == 1)
    }

    @Test func aReminderInAReadOnlyListIsLocked() async {
        let store = await makeStore()
        #expect(store.isLocked(store.reminder(2)!))
        #expect(!store.isLocked(store.reminder(1)!))
    }

    // MARK: Completion

    @Test func completingIsOptimisticThenTakesTheServersCopy() async throws {
        var done = Self.rows[0]
        done.completed = true
        done.sync.state = .syncing
        server.respond(.post, "/api/reminders/1/complete", value: done)
        let store = await makeStore()

        await store.toggle(store.reminder(1)!)

        #expect(store.reminder(1)?.completed == true)
        #expect(store.reminder(1)?.sync.state == .syncing)
        #expect(server.requests(.post, "/api/reminders/1/complete").count == 1)
        #expect(store.notice == nil)
    }

    @Test func aRefusedCompletionRollsBackAndShowsTheServersMessage() async throws {
        server.respond(.post, "/api/reminders/1/complete", status: 409, json: #"{"detail": "the reminder is gone from Apple Reminders"}"#)
        let store = await makeStore()

        await store.toggle(store.reminder(1)!)

        #expect(store.reminder(1)?.completed == false)
        #expect(store.notice?.kind == .failure)
        #expect(store.notice?.message == "the reminder is gone from Apple Reminders")
    }

    @Test func uncompletingUsesItsOwnEndpoint() async throws {
        var completed = Self.rows[0]
        completed.completed = true
        server.respond(.get, "/api/reminders", value: [completed])
        server.respond(.post, "/api/reminders/1/uncomplete", value: Self.rows[0])
        let store = await makeStore()

        await store.toggle(store.reminder(1)!)

        #expect(server.requests(.post, "/api/reminders/1/uncomplete").count == 1)
        #expect(store.reminder(1)?.completed == false)
    }

    @Test func aLockedReminderIsNeverSent() async {
        let store = await makeStore()
        await store.toggle(store.reminder(2)!)
        #expect(server.requests(.post, "/api/reminders/2/complete").isEmpty)
        #expect(store.reminder(2)?.completed == false)
    }

    // MARK: Quick-add

    @Test func addingSendsTheParsedFieldsToTheTargetList() async throws {
        let created = M.reminder(9, "Call the plumber", list: "work", due: "2026-11-17", time: "15:00", priority: 1, state: .syncing)
        server.respond(.post, "/api/reminders", status: 201, value: created)
        let store = await makeStore()
        let parsed = QuickAdd(title: "Call the plumber", dueDate: LocalDate("2026-11-17"), dueTime: LocalTime(hour: 15, minute: 0), priority: 1)

        let added = await store.add(RemindersQuickAddPlan(parsed, list: store.list("work")), to: store.list("work"))

        #expect(added)
        #expect(store.reminder(9)?.title == "Call the plumber")
        let body = try #require(server.requests(.post, "/api/reminders").first?.json)
        #expect(body == [
            "title": "Call the plumber", "list_id": "work", "due_date": "2026-11-17", "due_time": "15:00", "priority": 1,
        ])
    }

    @Test func aRefusedAddKeepsTheTextAndSaysWhy() async {
        server.respond(.post, "/api/reminders", status: 422, json: #"{"detail": "Google Tasks keeps no due time"}"#)
        let store = await makeStore()

        let added = await store.add(RemindersQuickAddPlan(QuickAdd(title: "Call"), list: nil), to: nil)

        #expect(!added)
        #expect(store.notice?.message == "Google Tasks keeps no due time")
    }

    // MARK: Edit

    @Test func savingSendsTheChangesAndTakesTheServersCopy() async throws {
        var renamed = Self.rows[0]
        renamed.title = "Water the ferns"
        renamed.sync.state = .syncing
        server.respond(.patch, "/api/reminders/1", value: renamed)
        let store = await makeStore()
        var changes = ReminderUpdate()
        changes.title = .value("Water the ferns")
        changes.dueDate = .null

        let failure = await store.save(store.reminder(1)!, changes)

        #expect(failure == nil)
        #expect(store.reminder(1)?.title == "Water the ferns")
        let body = try #require(server.requests(.patch, "/api/reminders/1").first?.json)
        #expect(body == ["title": "Water the ferns", "due_date": nil])
    }

    @Test func aRefusedSaveReturnsTheServersMessage() async {
        server.respond(.patch, "/api/reminders/1", status: 422, json: #"{"detail": "a reminder can only move within its account"}"#)
        let store = await makeStore()
        var changes = ReminderUpdate()
        changes.listId = .value("g1")

        let failure = await store.save(store.reminder(1)!, changes)

        #expect(failure?.message == "a reminder can only move within its account")
        #expect(store.reminder(1)?.title == "Water the plants")
    }

    // MARK: Failed ops

    @Test func retrySendsEachFailedOpAndReloads() async throws {
        server.respond(.post, "/api/reminders/ops/41/retry", value: Self.rows[2].sync.pendingOps[0])
        let store = await makeStore()
        let loadsBefore = server.requests(.get, "/api/reminders").count

        await store.retryFailed(store.reminder(3)!)

        #expect(server.requests(.post, "/api/reminders/ops/41/retry").count == 1)
        #expect(server.requests(.get, "/api/reminders").count == loadsBefore + 1)
        #expect(store.notice == nil)
    }

    @Test func withdrawDeletesTheOp() async throws {
        server.respond(.delete, "/api/reminders/ops/41", status: 204, json: "")
        let store = await makeStore()

        await store.withdrawFailed(store.reminder(3)!)

        #expect(server.requests(.delete, "/api/reminders/ops/41").count == 1)
        #expect(store.notice == nil)
    }

    @Test func aRefusedRetryShowsTheServersMessage() async {
        server.respond(.post, "/api/reminders/ops/41/retry", status: 409, json: #"{"detail": "only a failed op can be retried (this one is pending)"}"#)
        let store = await makeStore()

        await store.retryFailed(store.reminder(3)!)

        #expect(store.notice?.message == "only a failed op can be retried (this one is pending)")
    }

    // MARK: Sync

    @Test func syncNowPostsAndReloads() async {
        server.respond(.post, "/api/reminders/sync", value: [ReminderSyncOutcomeOut(accountId: 3, ok: true, lists: 2, reminders: 5)])
        let store = await makeStore()

        await store.syncNow()

        #expect(server.requests(.post, "/api/reminders/sync").count == 1)
        #expect(server.requests(.get, "/api/reminders/lists").count == 2)
        #expect(store.notice == nil)
        #expect(!store.isSyncing)
    }

    @Test func aFailedGoogleAccountIsReported() async {
        server.respond(.post, "/api/reminders/sync", value: [
            ReminderSyncOutcomeOut(accountId: 3, ok: false, lists: 0, reminders: 0, error: "token revoked"),
        ])
        let store = await makeStore()

        await store.syncNow()

        #expect(store.notice?.message == "token revoked")
    }

    @Test func pollsFastWhileAChangeIsOnItsWay() async {
        let store = await makeStore()
        #expect(store.pollInterval == .seconds(30))

        server.respond(.get, "/api/reminders/status", value: Self.status(pending: 1, waiting: true))
        await store.status.refresh()
        #expect(store.pollInterval == .seconds(5))

        server.respond(.get, "/api/reminders/status", value: Self.status())
        server.respond(.get, "/api/reminders", value: [M.reminder(1, "Water the plants", state: .waitingForDevice)])
        await store.refresh()
        #expect(store.pollInterval == .seconds(5))
    }

    // MARK: Deep links

    @Test func findFetchesAReminderThatIsNotLoaded() async {
        server.respond(.get, "/api/reminders/77", value: M.reminder(77, "Old one", completed: true))
        let store = await makeStore()

        #expect(await store.find(1)?.title == "Water the plants")
        #expect(await store.find(77)?.title == "Old one")
        #expect(await store.find(78) == nil)
        #expect(store.notice?.kind == .failure)
    }
}
