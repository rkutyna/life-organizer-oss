import EventKit
import Foundation

/// `ReminderStore` over EventKit. Shares the helper's one `EKEventStore`. It can create and
/// update reminders; it has no delete.
public final class EventKitReminderStore: ReminderStore, @unchecked Sendable {
    private let store: EKEventStore
    /// Give a reminder with a due time one alarm at that time when it has none (Reminders.app
    /// does the same), and move that alarm when the organizer moves the due time.
    private let alarmAtDueTime: Bool

    public init(store: EKEventStore, alarmAtDueTime: Bool = true) {
        self.store = store
        self.alarmAtDueTime = alarmAtDueTime
    }

    private func reminderCalendars() -> [EKCalendar] { store.calendars(for: .reminder) }

    public func lists() -> [ReminderListRecord] {
        reminderCalendars().map(Self.listRecord)
    }

    public func defaultListId() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    public func fetchReminders(listIds: [String], completedSince: Date?) async throws -> [ReminderRecord] {
        let wanted = Set(listIds)
        let calendars = reminderCalendars().filter { wanted.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let open = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let done = store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: nil, calendars: calendars)
        var seen = Set<String>()
        var out: [ReminderRecord] = []
        for record in try await fetch(open) + fetch(done) where seen.insert(record.localId).inserted {
            out.append(record)
        }
        return out
    }

    private func fetch(_ predicate: NSPredicate) async throws -> [ReminderRecord] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[ReminderRecord], Error>) in
            _ = store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else { cont.resume(throwing: ReminderStoreError.fetchFailed); return }
                cont.resume(returning: reminders.map(Self.record))
            }
        }
    }

    public func reminder(localId: String) -> ReminderRecord? {
        (store.calendarItem(withIdentifier: localId) as? EKReminder).map(Self.record)
    }

    public func reminders(externalId: String) -> [ReminderRecord] {
        store.calendarItems(withExternalIdentifier: externalId).compactMap { ($0 as? EKReminder).map(Self.record) }
    }

    public func create(listId: String, change: ReminderChange) throws -> ReminderRecord {
        guard let calendar = store.calendar(withIdentifier: listId), calendar.allowedEntityTypes.contains(.reminder) else {
            throw ReminderStoreError.listNotFound(listId)
        }
        guard calendar.allowsContentModifications else { throw ReminderStoreError.listReadOnly(calendar.title) }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        try apply(change, to: reminder)
        try store.save(reminder, commit: true)
        return Self.record(reminder)
    }

    public func update(localId: String, change: ReminderChange) throws -> ReminderRecord {
        guard let reminder = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            throw ReminderStoreError.notFound(localId)
        }
        try apply(change, to: reminder)
        try store.save(reminder, commit: true)
        return Self.record(reminder)
    }

    // MARK: mapping

    private func apply(_ change: ReminderChange, to r: EKReminder) throws {
        let v = change.values
        let f = change.fields
        if f.contains(.title) { r.title = v.title }
        if f.contains(.notes) { r.notes = v.notes.isEmpty ? nil : v.notes }
        if f.contains(.due) {
            let old = r.dueDateComponents
            let new = ReminderMapping.components(date: v.due_date, time: v.due_time)
            r.dueDateComponents = new
            if alarmAtDueTime { moveDueAlarm(r, from: old, to: new) }
        }
        if f.contains(.priority) { r.priority = ReminderMapping.eventKitPriority(v.priority) }
        if f.contains(.list), let id = change.listId {
            guard let cal = store.calendar(withIdentifier: id), cal.allowedEntityTypes.contains(.reminder) else {
                throw ReminderStoreError.listNotFound(id)
            }
            guard cal.allowsContentModifications else { throw ReminderStoreError.listReadOnly(cal.title) }
            r.calendar = cal
        }
        if f.contains(.completed) {
            if v.completed {
                r.isCompleted = true
                r.completionDate = change.completionDate ?? Date()
            } else {
                r.isCompleted = false
            }
        }
    }

    /// The due-time alarm: an absolute alarm at the old due time moves with it (or goes when
    /// the time is cleared); a reminder that gets a due time and has no alarm gets one.
    private func moveDueAlarm(_ r: EKReminder, from old: DateComponents?, to new: DateComponents?) {
        let oldAt = ReminderMapping.instant(of: old)
        let newAt = ReminderMapping.instant(of: new)
        if let oldAt {
            for alarm in r.alarms ?? [] {
                if let at = alarm.absoluteDate, abs(at.timeIntervalSince(oldAt)) < 1 { r.removeAlarm(alarm) }
            }
        }
        if let newAt, (r.alarms ?? []).isEmpty { r.addAlarm(EKAlarm(absoluteDate: newAt)) }
    }

    static func listRecord(_ cal: EKCalendar) -> ReminderListRecord {
        ReminderListRecord(id: cal.calendarIdentifier, title: cal.title, color: EventKitMapping.hex(cal.cgColor),
                           account: cal.source?.title, accountType: cal.source.map { EventKitMapping.sourceType($0.sourceType) },
                           writable: cal.allowsContentModifications)
    }

    static func record(_ r: EKReminder) -> ReminderRecord {
        let due = ReminderMapping.due(from: r.dueDateComponents)
        let values = ReminderValues(title: r.title ?? "", notes: r.notes ?? "", due_date: due.date, due_time: due.time,
                                    priority: ReminderMapping.organizerPriority(r.priority), completed: r.isCompleted)
        let external = r.calendarItemExternalIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        return ReminderRecord(localId: r.calendarItemIdentifier, externalId: external, listId: r.calendar?.calendarIdentifier ?? "",
                              values: values, completionDate: r.isCompleted ? r.completionDate : nil, url: r.url,
                              createdAt: r.creationDate, modifiedAt: r.lastModifiedDate)
    }
}
