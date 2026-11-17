import Foundation

extension OrganizerClient {
    /// Apple Reminders as the organizer shows them: `/api/reminders`.
    ///
    /// The server never changes the mirror at once: every write queues an op for the Mac
    /// helper and returns the reminder with `sync.state` "syncing". Apple Reminders stays the
    /// source of truth, and the organizer never deletes a reminder (so there is no delete).
    public var reminders: RemindersAPI { RemindersAPI(client: self) }
}

public struct RemindersAPI: Sendable {
    let client: OrganizerClient

    /// Open reminders, plus those completed in the last 30 days when `includeCompleted`.
    public func list(includeCompleted: Bool = true) async throws -> [ReminderOut] {
        try await client.send(API.Reminders.listReminders(includeCompleted: includeCompleted))
    }

    public func lists() async throws -> [ReminderListOut] {
        try await client.send(API.Reminders.reminderLists())
    }

    public func status() async throws -> ReminderStatusOut {
        try await client.send(API.Reminders.remindersStatus())
    }

    public func create(_ reminder: ReminderCreate) async throws -> ReminderOut {
        try await client.send(API.Reminders.createReminder(body: reminder))
    }

    /// Queues a change to the fields set in `changes`.
    public func update(id: Int, _ changes: ReminderUpdate) async throws -> ReminderOut {
        try await client.send(API.Reminders.updateReminder(reminderId: id, body: changes))
    }

    @discardableResult
    public func setDone(id: Int, _ done: Bool) async throws -> ReminderOut {
        try await client.send(
            done ? API.Reminders.completeReminder(reminderId: id) : API.Reminders.uncompleteReminder(reminderId: id))
    }

    /// Queues a failed op again.
    public func retry(opID: Int) async throws {
        _ = try await client.send(API.Reminders.retryOp(opId: opID))
    }

    /// Drops a pending or failed op. Withdrawing a create Apple Reminders never got removes it.
    public func withdraw(opID: Int) async throws {
        _ = try await client.send(API.Reminders.withdrawOp(opId: opID))
    }
}

extension ReminderOut {
    /// The ops Apple Reminders refused, oldest first: Retry and Withdraw act on each.
    public var failedOps: [ReminderOpOut] {
        sync.pendingOps.filter { $0.state == .failed }
    }
}

extension Array where Element == ReminderListOut {
    /// A list Apple Reminders will not let the helper write (EventKit's
    /// allowsContentModifications is false): its reminders cannot be checked off or edited.
    public func isReadOnly(_ listID: String?) -> Bool {
        guard let listID else { return false }
        return contains { $0.id == listID && !$0.writable }
    }
}
