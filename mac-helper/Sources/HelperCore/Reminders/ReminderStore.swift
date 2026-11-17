import Foundation

/// A reminders list as the sync sees it.
public struct ReminderListRecord: Equatable, Sendable {
    public var id: String
    public var title: String
    public var color: String?
    public var account: String?
    public var accountType: String?
    public var writable: Bool

    public init(id: String, title: String, color: String? = nil, account: String? = nil, accountType: String? = nil, writable: Bool = true) {
        self.id = id; self.title = title; self.color = color; self.account = account
        self.accountType = accountType; self.writable = writable
    }
}

/// One reminder as the sync sees it: identity, list, comparable values and timestamps.
public struct ReminderRecord: Equatable, Sendable {
    /// `calendarItemIdentifier`: device-local, the handle for reads and writes on this Mac.
    public var localId: String
    /// `calendarItemExternalIdentifier`: stable across devices; nil until the account assigns one.
    public var externalId: String?
    public var listId: String
    public var values: ReminderValues
    public var completionDate: Date?
    public var url: URL?
    public var createdAt: Date?
    /// `lastModifiedDate`: what the conflict rule compares with an op's queue time.
    public var modifiedAt: Date?

    public init(localId: String, externalId: String?, listId: String, values: ReminderValues, completionDate: Date? = nil,
                url: URL? = nil, createdAt: Date? = nil, modifiedAt: Date? = nil) {
        self.localId = localId; self.externalId = externalId; self.listId = listId; self.values = values
        self.completionDate = completionDate; self.url = url; self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }
}

/// What to write to a reminder: only `fields` change, to their value in `values`.
public struct ReminderChange: Equatable, Sendable {
    public var fields: Set<ReminderField>
    public var values: ReminderValues
    /// For `.list`.
    public var listId: String?
    /// For `.completed` set to true; nil means now.
    public var completionDate: Date?

    public init(fields: Set<ReminderField>, values: ReminderValues, listId: String? = nil, completionDate: Date? = nil) {
        self.fields = fields; self.values = values; self.listId = listId; self.completionDate = completionDate
    }

    public var isEmpty: Bool { fields.isEmpty }
}

public enum ReminderStoreError: Error, CustomStringConvertible, Equatable {
    case notAuthorized(String)
    case fetchFailed
    case notFound(String)
    case listNotFound(String)
    case listReadOnly(String)

    public var description: String {
        switch self {
        case .notAuthorized(let s):
            return "reminders access is \(s); the LaunchAgent asks on first run (approve the prompt), or turn it on in System Settings > Privacy & Security > Reminders"
        case .fetchFailed: return "EventKit returned no reminders (fetch failed)"
        case .notFound(let id): return "reminder \(id) not found in Apple Reminders"
        case .listNotFound(let id): return "reminders list \(id) not found"
        case .listReadOnly(let title): return "reminders list \(title) is read-only"
        }
    }
}

/// The reminders store, behind a protocol so the sync logic is tested without EventKit
/// (`EventKitReminderStore` is the real one). Every write commits on its own. There is no
/// delete: the helper never deletes a reminder.
public protocol ReminderStore: AnyObject {
    func lists() -> [ReminderListRecord]
    func defaultListId() -> String?
    /// Incomplete reminders in `listIds`, plus those completed since `completedSince` (nil: all).
    func fetchReminders(listIds: [String], completedSince: Date?) async throws -> [ReminderRecord]
    func reminder(localId: String) -> ReminderRecord?
    func reminders(externalId: String) -> [ReminderRecord]
    func create(listId: String, change: ReminderChange) throws -> ReminderRecord
    func update(localId: String, change: ReminderChange) throws -> ReminderRecord
}
