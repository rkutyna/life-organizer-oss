import Foundation
import OrganizerAPI
import OrganizerCore

// Pure helpers for the Reminders screen: which reminders a view shows and in what sections, the
// list groups, what quick-add can send to a list, and the edit sheet's draft. Nonisolated, so tests
// and previews use them anywhere.

/// What the screen shows: a smart view or one list.
nonisolated enum RemindersScope: Hashable, Sendable {
    /// Overdue and due today.
    case today
    /// Due after today, by day.
    case upcoming
    /// Every reminder: overdue, today, upcoming, no date, completed recently.
    case all
    /// One list, by its id.
    case list(String)

    /// The form kept in `@AppStorage` ("today", "list:<id>").
    var storageKey: String {
        switch self {
        case .today: "today"
        case .upcoming: "upcoming"
        case .all: "all"
        case .list(let id): "list:\(id)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "today": self = .today
        case "upcoming": self = .upcoming
        case "all": self = .all
        default:
            guard storageKey.hasPrefix("list:"), storageKey.count > 5 else { return nil }
            self = .list(String(storageKey.dropFirst(5)))
        }
    }

    var listID: String? {
        if case .list(let id) = self { return id }
        return nil
    }
}

/// One section of the reminders list.
nonisolated struct RemindersSection: Identifiable, Equatable, Sendable {
    enum Kind: Hashable, Sendable {
        case overdue, today, upcoming, undated, completed
        /// One day of the Upcoming view.
        case day(LocalDate)
    }

    let kind: Kind
    let title: String
    var reminders: [ReminderOut]

    var id: String {
        switch kind {
        case .overdue: "overdue"
        case .today: "today"
        case .upcoming: "upcoming"
        case .undated: "undated"
        case .completed: "completed"
        case .day(let day): "day:\(day.string)"
        }
    }

    var isOverdue: Bool { kind == .overdue }
    var isCompleted: Bool { kind == .completed }
}

nonisolated enum RemindersSections {
    /// Completed reminders shown, newest first (the server keeps 30 days of them).
    static let completedLimit = 30

    /// The reminders a scope shows, in display order.
    static func rows(_ all: [ReminderOut], scope: RemindersScope, today: LocalDate) -> [ReminderOut] {
        sorted(all.filter { matches($0, scope: scope, today: today) })
    }

    static func matches(_ reminder: ReminderOut, scope: RemindersScope, today: LocalDate) -> Bool {
        switch scope {
        case .today:
            guard !reminder.completed, let due = reminder.dueDate else { return false }
            return due <= today
        case .upcoming:
            guard !reminder.completed, let due = reminder.dueDate else { return false }
            return due > today
        case .all:
            return true
        case .list(let id):
            return reminder.listId == id
        }
    }

    /// Open reminders a scope counts (the sidebar's badges).
    static func openCount(_ all: [ReminderOut], scope: RemindersScope, today: LocalDate) -> Int {
        all.count { !$0.completed && matches($0, scope: scope, today: today) }
    }

    /// The scope's sections, empty ones left out. Upcoming groups by day; the others split by due
    /// date, then completed recently (newest first, at most `completedLimit`).
    static func make(_ all: [ReminderOut], scope: RemindersScope, today: LocalDate,
                     now: Date = Date(), calendar: Calendar = .current) -> [RemindersSection] {
        let rows = rows(all, scope: scope, today: today)
        if scope == .upcoming {
            var days: [LocalDate: [ReminderOut]] = [:]
            for reminder in rows {
                guard let due = reminder.dueDate else { continue }
                days[due, default: []].append(reminder)
            }
            return days.keys.sorted().map { day in
                RemindersSection(kind: .day(day), title: DayLabels.day(day, now: now, calendar: calendar),
                                 reminders: days[day] ?? [])
            }
        }
        var overdue: [ReminderOut] = [], dueToday: [ReminderOut] = [], upcoming: [ReminderOut] = []
        var undated: [ReminderOut] = [], completed: [ReminderOut] = []
        for reminder in rows {
            if reminder.completed {
                completed.append(reminder)
            } else if let due = reminder.dueDate {
                if due < today { overdue.append(reminder) } else if due == today { dueToday.append(reminder) } else { upcoming.append(reminder) }
            } else {
                undated.append(reminder)
            }
        }
        let all: [RemindersSection] = [
            RemindersSection(kind: .overdue, title: "Overdue", reminders: overdue),
            RemindersSection(kind: .today, title: "Today", reminders: dueToday),
            RemindersSection(kind: .upcoming, title: "Upcoming", reminders: upcoming),
            RemindersSection(kind: .undated, title: "No Date", reminders: undated),
            RemindersSection(kind: .completed, title: "Completed Recently", reminders: Array(completed.prefix(completedLimit))),
        ]
        return all.filter { !$0.reminders.isEmpty }
    }

    /// The server's display order (router.display_order): open by due date (undated last, all-day
    /// before timed, then by time), priority, title; then completed, newest first.
    static func sorted(_ rows: [ReminderOut]) -> [ReminderOut] {
        rows.sorted { a, b in
            if a.completed != b.completed { return !a.completed }
            if a.completed {
                let left = a.completedAt ?? .distantPast, right = b.completedAt ?? .distantPast
                if left != right { return left > right }
            } else {
                if (a.dueDate == nil) != (b.dueDate == nil) { return a.dueDate != nil }
                if let left = a.dueDate, let right = b.dueDate, left != right { return left < right }
                if (a.dueTime == nil) != (b.dueTime == nil) { return a.dueTime == nil }
                if let left = a.dueTime, let right = b.dueTime, left != right { return left < right }
                if (a.priority == nil) != (b.priority == nil) { return a.priority != nil }
                if let left = a.priority, let right = b.priority, left != right { return left < right }
            }
            let left = a.title.lowercased(), right = b.title.lowercased()
            if left != right { return left < right }
            return a.id < b.id
        }
    }
}

/// The lists of one account: Apple Reminders, or one Google account's task lists.
nonisolated struct RemindersListGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var lists: [ReminderListOut]

    /// Lists grouped by account, in the server's order (Apple first, then each Google account).
    static func groups(_ lists: [ReminderListOut]) -> [RemindersListGroup] {
        var groups: [RemindersListGroup] = []
        for list in lists {
            let key = list.source == .google ? "google:\(list.accountId.map(String.init) ?? list.account)" : "apple"
            if let index = groups.firstIndex(where: { $0.id == key }) {
                groups[index].lists.append(list)
            } else {
                let title = list.source == .google
                    ? "Google Tasks · \(list.account)"
                    : (list.account.isEmpty ? "Apple Reminders" : "Apple Reminders · \(list.account)")
                groups.append(RemindersListGroup(id: key, title: title, lists: [list]))
            }
        }
        return groups
    }
}

nonisolated enum RemindersProvider {
    /// "Apple Reminders" or "Google Tasks", for messages about where a change goes.
    static func name(_ source: ReminderOut.Source) -> String {
        switch source {
        case .google: "Google Tasks"
        case .apple: "Apple Reminders"
        case .unknown(let raw): raw
        }
    }

    static func name(_ source: ReminderListOut.Source) -> String {
        switch source {
        case .google: "Google Tasks"
        case .apple: "Apple Reminders"
        case .unknown(let raw): raw
        }
    }
}

nonisolated enum RemindersPriority {
    static let options: [(value: Int, label: String)] = [(1, "High"), (2, "Medium"), (3, "Low")]

    static func label(_ priority: Int?) -> String? {
        options.first { $0.value == priority }?.label
    }
}

// MARK: - Quick-add

/// What quick-add will send to a list: the parsed line, minus what the list cannot hold (Google
/// Tasks keeps a due date but no time and no priority; the server refuses both, so quick-add
/// drops them first and the preview says so).
nonisolated struct RemindersQuickAddPlan: Equatable, Sendable {
    var fields: QuickAdd
    /// "time", "priority": parsed but left out for this list.
    var dropped: [String]

    init(_ parsed: QuickAdd, list: ReminderListOut?) {
        var fields = parsed
        var dropped: [String] = []
        if let list {
            if !list.supportsTime, fields.dueTime != nil {
                fields.dueTime = nil
                dropped.append("time")
            }
            if !list.supportsPriority, fields.priority != nil {
                fields.priority = nil
                dropped.append("priority")
            }
        }
        self.fields = fields
        self.dropped = dropped
    }

    /// Whether the preview line has anything to say beyond the title.
    var hasPreview: Bool {
        fields.dueDate != nil || fields.priority != nil || !dropped.isEmpty
    }

    /// "Google Tasks keeps no time; it is left out".
    func droppedNote(provider: String) -> String? {
        guard !dropped.isEmpty else { return nil }
        return "\(provider) keeps no \(dropped.joined(separator: " or ")); it is left out"
    }

    func request(listID: String?) -> ReminderCreate {
        ReminderCreate(
            title: fields.title,
            listId: .ifPresent(listID),
            dueDate: .ifPresent(fields.dueDate),
            dueTime: fields.dueDate == nil ? .omitted : .ifPresent(fields.dueTime),
            priority: .ifPresent(fields.priority)
        )
    }
}

nonisolated enum RemindersTarget {
    /// The list a new reminder goes into: the one being viewed, else the one last picked, else the
    /// default list, else the first writable one. Read-only lists never take one.
    static func resolve(_ lists: [ReminderListOut], viewing: String?, remembered: String?) -> ReminderListOut? {
        let writable = lists.filter(\.writable)
        func byID(_ id: String?) -> ReminderListOut? {
            guard let id, !id.isEmpty else { return nil }
            return writable.first { $0.id == id }
        }
        return byID(viewing) ?? byID(remembered) ?? writable.first(where: \.isDefault) ?? writable.first
    }
}

// MARK: - Edit sheet

/// The edit sheet's copy of a reminder, and the PATCH that turns it back into changes.
nonisolated struct RemindersDraft: Equatable, Sendable {
    var title: String
    var notes: String
    var hasDate: Bool
    var date: Date
    var hasTime: Bool
    var time: Date
    var priority: Int?
    var listID: String?

    init(_ reminder: ReminderOut, calendar: Calendar = .current, now: Date = Date()) {
        title = reminder.title
        notes = reminder.notes
        hasDate = reminder.dueDate != nil
        let day = reminder.dueDate ?? .today(calendar: calendar, now: now)
        date = day.date(in: calendar)
        hasTime = reminder.dueTime != nil
        time = (reminder.dueTime ?? LocalTime(hour: 9, minute: 0)).date(on: day, calendar: calendar)
        priority = reminder.priority
        listID = reminder.listId
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    func dueDate(calendar: Calendar = .current) -> LocalDate? {
        hasDate ? LocalDate(date, calendar: calendar) : nil
    }

    func dueTime(calendar: Calendar = .current) -> LocalTime? {
        hasDate && hasTime ? LocalTime(time, calendar: calendar) : nil
    }

    /// Only what changed. The due date and time travel together, as the server expects; a list
    /// without times (Google Tasks) never gets one, nor a priority when it has none.
    func changes(from original: RemindersDraft, supportsTime: Bool, supportsPriority: Bool,
                 calendar: Calendar = .current) -> ReminderUpdate {
        var changes = ReminderUpdate()
        if trimmedTitle != original.trimmedTitle, !trimmedTitle.isEmpty { changes.title = .value(trimmedTitle) }
        if notes != original.notes { changes.notes = .value(notes) }
        let due = dueDate(calendar: calendar), time = supportsTime ? dueTime(calendar: calendar) : nil
        let originalTime = supportsTime ? original.dueTime(calendar: calendar) : nil
        if due != original.dueDate(calendar: calendar) || time != originalTime {
            changes.dueDate = .orNull(due)
            if due != nil, supportsTime { changes.dueTime = .orNull(time) }
        }
        if supportsPriority, priority != original.priority { changes.priority = .orNull(priority) }
        if listID != original.listID, let listID { changes.listId = .value(listID) }
        return changes
    }
}

// MARK: - Sync status

/// The module-level sync line from `/api/reminders/status`.
nonisolated struct RemindersSyncSummary: Equatable, Sendable {
    enum Tone: Sendable { case ok, busy, waiting, failed }

    let tone: Tone
    let title: String

    init(_ status: ReminderStatusOut?) {
        guard let status else {
            tone = .ok
            title = "Sync"
            return
        }
        if status.failedOps > 0 {
            tone = .failed
            title = status.failedOps == 1 ? "1 change failed" : "\(status.failedOps) changes failed"
        } else if status.waitingForDevice {
            tone = .waiting
            title = "Waiting for Mac"
        } else if status.pendingOps > 0 {
            tone = .busy
            title = status.pendingOps == 1 ? "Syncing 1 change" : "Syncing \(status.pendingOps) changes"
        } else {
            tone = .ok
            title = "Up to date"
        }
    }

    var systemImage: String {
        switch tone {
        case .ok: "checkmark.icloud"
        case .busy: "arrow.triangle.2.circlepath.icloud"
        case .waiting: "clock"
        case .failed: "exclamationmark.icloud"
        }
    }

    /// Whether the Mac helper is checking the queue, in words.
    static func helperLine(_ status: ReminderStatusOut, now: Date = Date()) -> String {
        if status.helperPolling { return "The Mac helper is checking for changes." }
        if let last = status.lastOpsPollAt {
            return "The Mac helper last checked for changes \(Freshness.age(of: last, now: now))."
        }
        return "The Mac helper has not checked for changes yet."
    }

    /// "2 pending · 1 failed", or nil when nothing is queued.
    static func queueLine(_ status: ReminderStatusOut, now: Date = Date()) -> String? {
        var parts: [String] = []
        if status.pendingOps > 0 {
            var pending = "\(status.pendingOps) pending"
            if let oldest = status.oldestPendingAt { pending += " (oldest \(Freshness.age(of: oldest, now: now)))" }
            parts.append(pending)
        }
        if status.failedOps > 0 { parts.append("\(status.failedOps) failed") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One source's freshness: "just now", "3 hours ago", "failing", "never synced".
    static func freshness(_ source: SourceStatusOut, now: Date = Date()) -> String {
        if source.state == .error { return "failing" }
        guard let last = source.lastSuccessAt else { return "never synced" }
        return Freshness.age(of: last, now: now)
    }
}
