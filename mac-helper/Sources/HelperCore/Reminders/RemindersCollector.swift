import Foundation

/// Apple Reminders -> `POST /api/ingest/reminders`: every list, their incomplete reminders plus
/// those completed in the last `completedDays`. Read-only: nothing is written.
public final class RemindersCollector {
    private let store: ReminderStore
    private let completedDays: Int

    public init(store: ReminderStore, completedDays: Int) {
        self.store = store
        self.completedDays = completedDays
    }

    public func collect(now: Date = Date()) async throws -> RemindersBody {
        let lists = store.lists().sorted { ($0.account ?? "", $0.title, $0.id) < ($1.account ?? "", $1.title, $1.id) }
        let listIds = Set(lists.map(\.id))
        let since = Calendar.current.date(byAdding: .day, value: -max(0, completedDays), to: now)
        let reminders = try await store.fetchReminders(listIds: lists.map(\.id), completedSince: since)
            .filter { listIds.contains($0.listId) }
            .sorted { ($0.listId, $0.externalId ?? $0.localId, $0.localId) < ($1.listId, $1.externalId ?? $1.localId, $1.localId) }
        let defaultId = store.defaultListId().flatMap { listIds.contains($0) ? $0 : nil }
        return RemindersBody(lists: lists.map(ReminderListInfo.init), default_list_id: defaultId,
                             reminders: reminders.map(ReminderInfo.init))
    }
}
