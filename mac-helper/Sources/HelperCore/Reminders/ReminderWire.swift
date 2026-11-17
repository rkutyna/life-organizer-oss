import Foundation

// Wire types for the Reminders sync. Property names are the JSON keys.

// MARK: POST /api/ingest/reminders

/// A full snapshot of every Apple Reminders list: lists and reminders absent from it are gone.
public struct RemindersBody: Codable, Equatable, Sendable {
    public var lists: [ReminderListInfo]
    @NullCodable public var default_list_id: String?
    public var reminders: [ReminderInfo]

    public init(lists: [ReminderListInfo], default_list_id: String?, reminders: [ReminderInfo]) {
        self.lists = lists; self.default_list_id = default_list_id; self.reminders = reminders
    }
}

public struct ReminderListInfo: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    @NullCodable public var color: String?
    @NullCodable public var account: String?
    @NullCodable public var account_type: String?
    public var writable: Bool

    public init(_ r: ReminderListRecord) {
        id = r.id; title = r.title; color = r.color; account = r.account; account_type = r.accountType; writable = r.writable
    }
}

public struct ReminderInfo: Codable, Equatable, Sendable {
    @NullCodable public var external_id: String?
    public var local_id: String
    public var list_id: String
    public var title: String
    public var notes: String
    @NullCodable public var due_date: String?
    @NullCodable public var due_time: String?
    @NullCodable public var priority: Int?
    public var completed: Bool
    @NullCodable public var completed_at: Date?
    @NullCodable public var url: String?
    @NullCodable public var created_at: Date?
    @NullCodable public var modified_at: Date?

    public init(_ r: ReminderRecord) {
        external_id = r.externalId; local_id = r.localId; list_id = r.listId
        title = r.values.title; notes = r.values.notes; due_date = r.values.due_date; due_time = r.values.due_time
        priority = r.values.priority; completed = r.values.completed; completed_at = r.completionDate
        url = r.url?.absoluteString; created_at = r.createdAt; modified_at = r.modifiedAt
    }
}

// MARK: GET /api/ingest/reminders/ops

/// An op's `fields` or `base`: which keys are present matters (absent = leave as is).
public struct OpFields: Decodable, Equatable, Sendable {
    public var present: Set<String>
    public var title: String?
    public var notes: String?
    public var due_date: String?
    public var due_time: String?
    public var priority: Int?
    public var list_id: String?
    public var completed: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable { case title, notes, due_date, due_time, priority, list_id, completed }

    public init(present: Set<String> = [], title: String? = nil, notes: String? = nil, due_date: String? = nil, due_time: String? = nil,
                priority: Int? = nil, list_id: String? = nil, completed: Bool? = nil) {
        self.present = present; self.title = title; self.notes = notes; self.due_date = due_date
        self.due_time = due_time.map(ReminderMapping.minuteTime); self.priority = priority; self.list_id = list_id; self.completed = completed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = Set(CodingKeys.allCases.filter { c.contains($0) }.map(\.rawValue))
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        due_date = try c.decodeIfPresent(String.self, forKey: .due_date)
        due_time = try c.decodeIfPresent(String.self, forKey: .due_time).map(ReminderMapping.minuteTime)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        list_id = try c.decodeIfPresent(String.self, forKey: .list_id)
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed)
    }

    /// The value fields this op sets (due_date/due_time are one field).
    public var valueFields: [ReminderField] {
        var out: [ReminderField] = []
        if present.contains("title") { out.append(.title) }
        if present.contains("notes") { out.append(.notes) }
        if present.contains("due_date") || present.contains("due_time") { out.append(.due) }
        if present.contains("priority") { out.append(.priority) }
        return out
    }

    public func has(_ field: ReminderField) -> Bool {
        switch field {
        case .due: return present.contains("due_date") || present.contains("due_time")
        case .list: return present.contains("list_id")
        default: return present.contains(field.rawValue)
        }
    }

    /// `values` with every present value field taken from this op.
    public func applied(to values: ReminderValues) -> ReminderValues {
        var v = values
        if present.contains("title") { v.title = title ?? "" }
        if present.contains("notes") { v.notes = notes ?? "" }
        if has(.due) { v.due_date = due_date; v.due_time = due_date == nil ? nil : due_time }
        if present.contains("priority") { v.priority = priority }
        if present.contains("completed"), let completed { v.completed = completed }
        return v
    }
}

public struct ReminderOp: Decodable, Equatable, Sendable {
    public var id: Int
    public var reminder_id: Int
    /// create | update | complete | uncomplete
    public var kind: String
    public var external_id: String?
    public var local_id: String?
    public var fields: OpFields
    public var base: OpFields
    public var queued_at: Date
    /// The server instance the op came from (the response's `instance_id`, copied onto each op
    /// by `ReminderOpsResponse.instancedOps`). nil: a server that sends none.
    public var instance: String?

    enum CodingKeys: String, CodingKey { case id, reminder_id, kind, external_id, local_id, fields, base, queued_at }

    public init(id: Int, reminder_id: Int, kind: String, external_id: String? = nil, local_id: String? = nil,
                fields: OpFields = OpFields(), base: OpFields = OpFields(), queued_at: Date, instance: String? = nil) {
        self.id = id; self.reminder_id = reminder_id; self.kind = kind; self.external_id = external_id
        self.local_id = local_id; self.fields = fields; self.base = base; self.queued_at = queued_at
        self.instance = instance
    }

    /// `fields` and `base` may be absent or null (a complete op has no fields; a create has an
    /// empty base): both read as no keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        reminder_id = try c.decode(Int.self, forKey: .reminder_id)
        kind = try c.decode(String.self, forKey: .kind)
        external_id = try c.decodeIfPresent(String.self, forKey: .external_id)
        local_id = try c.decodeIfPresent(String.self, forKey: .local_id)
        fields = try c.decodeIfPresent(OpFields.self, forKey: .fields) ?? OpFields()
        base = try c.decodeIfPresent(OpFields.self, forKey: .base) ?? OpFields()
        queued_at = try c.decode(Date.self, forKey: .queued_at)
    }
}

public struct ReminderOpsResponse: Decodable, Sendable {
    public var ops: [ReminderOp]
    public var server_time: Date?
    /// The server database's identity; op ids are unique only within it.
    public var instance_id: String?

    /// `ops`, each carrying `instance_id`.
    public var instancedOps: [ReminderOp] {
        ops.map { var op = $0; op.instance = instance_id; return op }
    }
}

// MARK: POST /api/ingest/reminders/ops/{id}/ack

/// Whose value a field kept when it changed on both sides.
public enum ConflictWinner: String, Codable, Sendable {
    /// Apple Reminders' value (it changed after the op was queued).
    case provider
    /// The organizer's value (the op was queued after Reminders last changed).
    case organizer
}

public struct OpConflict: Codable, Equatable, Sendable {
    /// title | notes | due | priority | completed | list
    public var field: String
    /// provider | organizer: whose value the reminder now holds.
    public var kept: String
    @NullCodable public var provider_value: String?
    @NullCodable public var organizer_value: String?

    public init(field: ReminderField, kept: ConflictWinner, provider: String?, organizer: String?) {
        self.field = field.rawValue; self.kept = kept.rawValue; provider_value = provider; organizer_value = organizer
    }
}

public struct OpAck: Codable, Equatable, Sendable {
    public var ok: Bool
    @NullCodable public var external_id: String?
    @NullCodable public var local_id: String?
    @NullCodable public var error: String?
    public var conflicts: [OpConflict]
    /// The server instance the op came from; the server refuses an ack meant for another (409).
    @NullCodable public var instance_id: String?

    public init(ok: Bool, external_id: String?, local_id: String?, error: String?, conflicts: [OpConflict],
                instance_id: String? = nil) {
        self.ok = ok; self.external_id = external_id; self.local_id = local_id; self.error = error
        self.conflicts = conflicts; self.instance_id = instance_id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        external_id = try c.decodeIfPresent(String.self, forKey: .external_id)
        local_id = try c.decodeIfPresent(String.self, forKey: .local_id)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        conflicts = try c.decodeIfPresent([OpConflict].self, forKey: .conflicts) ?? []
        instance_id = try c.decodeIfPresent(String.self, forKey: .instance_id)
    }

    public static func success(external: String? = nil, local: String? = nil, conflicts: [OpConflict] = []) -> OpAck {
        OpAck(ok: true, external_id: external, local_id: local, error: nil, conflicts: conflicts)
    }

    public static func failure(_ error: String) -> OpAck {
        OpAck(ok: false, external_id: nil, local_id: nil, error: error, conflicts: [])
    }

    /// This ack, addressed to the instance `op` came from.
    public func addressed(to op: ReminderOp) -> OpAck {
        var ack = self
        ack.instance_id = op.instance
        return ack
    }
}
