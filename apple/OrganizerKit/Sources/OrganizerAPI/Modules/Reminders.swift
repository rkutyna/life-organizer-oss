import Foundation

extension OrganizerClient {
    /// Reminders from Apple Reminders (through the Mac helper) and Google Tasks: `/api/reminders`.
    ///
    /// The server never changes a provider's copy directly: every write queues an op and returns
    /// the reminder with the op applied on top and `sync` saying where it stands. A Google change
    /// is usually applied before the answer comes back (`synced`); an Apple change waits for the
    /// Mac helper (`syncing`, or `waitingForDevice` while the Mac is not polling). The organizer
    /// never deletes a reminder, so there is no delete.
    public var reminders: RemindersAPI { RemindersAPI(client: self) }
}

public struct RemindersAPI: Sendable {
    let client: OrganizerClient

    /// Open reminders by due date (undated last), then, when `includeCompleted`, those completed
    /// in the last 30 days, newest first. `list` narrows to one list id; `dated` to reminders
    /// with (true) or without (false) a due date.
    public func list(list: String? = nil, includeCompleted: Bool = true, dated: Bool? = nil) async throws -> [ReminderOut] {
        try await client.send(API.Reminders.listReminders(list: list, includeCompleted: includeCompleted, dated: dated))
    }

    public func get(id: Int) async throws -> ReminderOut {
        try await client.send(API.Reminders.getReminder(reminderId: id))
    }

    /// Every list: Apple Reminders first, then each Google account's task lists.
    public func lists() async throws -> [ReminderListOut] {
        try await client.send(API.Reminders.reminderLists())
    }

    /// Each source's freshness, whether the helper is polling, and what is queued or failed.
    public func status() async throws -> ReminderStatusOut {
        try await client.send(API.Reminders.remindersStatus())
    }

    /// Queues a new reminder. Google Tasks lists refuse a due time and a priority (422).
    public func create(_ reminder: ReminderCreate) async throws -> ReminderOut {
        try await client.send(API.Reminders.createReminder(body: reminder))
    }

    /// Queues a change to the fields set in `changes`. Clearing the due date also clears the time.
    public func update(id: Int, _ changes: ReminderUpdate) async throws -> ReminderOut {
        try await client.send(API.Reminders.updateReminder(reminderId: id, body: changes))
    }

    /// Queues a completion (or un-completing). The server answers with the reminder as shown.
    @discardableResult
    public func setDone(id: Int, _ done: Bool) async throws -> ReminderOut {
        try await client.send(
            done ? API.Reminders.completeReminder(reminderId: id) : API.Reminders.uncompleteReminder(reminderId: id))
    }

    /// Polls every Google Tasks account now (and retries pending Google ops). Apple Reminders
    /// syncs whenever the Mac helper pushes, so this does nothing for it.
    @discardableResult
    public func syncNow() async throws -> [ReminderSyncOutcomeOut] {
        try await client.send(API.Reminders.syncNow())
    }

    /// Queued changes, newest first (pending and failed unless `state` says otherwise).
    public func ops(reminderID: Int? = nil, state: API.Reminders.ListOpsState? = nil) async throws -> [ReminderOpOut] {
        try await client.send(API.Reminders.listOps(state: state, reminderId: reminderID))
    }

    /// Queues a failed op again. A Google op is applied again at once.
    @discardableResult
    public func retry(opID: Int) async throws -> ReminderOpOut {
        try await client.send(API.Reminders.retryOp(opId: opID))
    }

    /// Drops a pending or failed op. Withdrawing a create the provider never got removes the
    /// reminder from the organizer.
    public func withdraw(opID: Int) async throws {
        _ = try await client.send(API.Reminders.withdrawOp(opId: opID))
    }
}

extension ReminderOut {
    /// The ops the provider refused, oldest first: Retry and Withdraw act on each.
    public var failedOps: [ReminderOpOut] {
        sync.pendingOps.filter { $0.state == .failed }
    }

    /// A change is on its way to the provider (queued, or applied and not yet mirrored back).
    public var isSyncInFlight: Bool {
        sync.state == .syncing || sync.state == .waitingForDevice
    }
}

extension Array where Element == ReminderListOut {
    /// The list with this id.
    public func list(_ id: String?) -> ReminderListOut? {
        guard let id else { return nil }
        return first { $0.id == id }
    }

    /// A list the provider will not let the organizer write (some shared Apple lists): its
    /// reminders cannot be checked off or edited.
    public func isReadOnly(_ listID: String?) -> Bool {
        list(listID).map { !$0.writable } ?? false
    }
}
