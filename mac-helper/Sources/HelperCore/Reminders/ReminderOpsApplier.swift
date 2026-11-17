import Foundation

/// Applies the organizer's queued reminder ops with EventKit (through `ReminderStore`).
///
/// Rules:
/// - Ops apply in queue order. Re-applying one is harmless: a field already at the op's value is
///   skipped, completing a completed reminder is a no-op, and a create remembered in
///   `created_ops` is acked again rather than repeated.
/// - The loop rule: each field in `fields` is compared with `base` (what the organizer believed
///   Reminders held when it queued the op). A field still at `base` takes the op's value. A field
///   that changed in Reminders since is a conflict: the last writer wins, the reminder's
///   lastModifiedDate against the op's `queued_at`. Each conflict is reported in the ack and
///   logged. Fields merge: each side keeps what only it changed.
/// - Completion is never lost: `complete` always applies; `uncomplete` yields to a completion
///   made in Reminders after it was queued.
/// - The target is found by external id, then local id. Nothing is ever deleted, and read-only
///   lists are never written.
public final class ReminderOpsApplier {
    public enum Outcome: Equatable {
        /// Ack the op with this result.
        case ack(OpAck)
        /// Leave it pending (it is re-sent): its target is not resolvable yet.
        case later(String)
    }

    private let store: ReminderStore
    public private(set) var state: RemindersState
    /// reminder_id -> local id of reminders created in this batch, for ops queued right after a create.
    private var createdInBatch: [Int: String] = [:]

    public init(store: ReminderStore, state: RemindersState) {
        self.store = store
        self.state = state
    }

    public func apply(_ op: ReminderOp, now: Date = Date()) -> Outcome {
        switch op.kind {
        case "create": return create(op, now: now)
        case "update", "complete", "uncomplete": break
        default: return .ack(.failure("unknown op kind \(op.kind)"))
        }
        guard let target = resolve(op) else {
            if op.external_id == nil && op.local_id == nil && createdInBatch[op.reminder_id] == nil {
                return .later("waiting for the reminder's create")
            }
            return .ack(.failure("the reminder is not in Apple Reminders (deleted?)"))
        }
        switch op.kind {
        case "complete": return complete(op, target, now: now)
        case "uncomplete": return uncomplete(op, target)
        default: return update(op, target)
        }
    }

    // MARK: kinds

    private func create(_ op: ReminderOp, now: Date) -> Outcome {
        if let prior = state.created(op: op.id), let existing = store.reminder(localId: prior.local_id) {
            createdInBatch[op.reminder_id] = existing.localId
            return .ack(.success(external: existing.externalId, local: existing.localId))
        }
        guard let listId = op.fields.list_id ?? store.defaultListId() else {
            return .ack(.failure("no list given and Reminders has no default list"))
        }
        if let problem = listProblem(listId) { return .ack(.failure(problem)) }
        let values = op.fields.applied(to: ReminderValues(title: ""))
        var fields = Set(op.fields.valueFields)
        if values.completed { fields.insert(.completed) }
        let change = ReminderChange(fields: fields, values: values, completionDate: values.completed ? now : nil)
        do {
            let made = try store.create(listId: listId, change: change)
            state.recordCreated(op: op.id, .init(local_id: made.localId, external_id: made.externalId, at: now))
            createdInBatch[op.reminder_id] = made.localId
            return .ack(.success(external: made.externalId, local: made.localId))
        } catch {
            return .ack(.failure("\(error)"))
        }
    }

    private func update(_ op: ReminderOp, _ target: ReminderRecord) -> Outcome {
        let current = target.values
        let wanted = op.fields.applied(to: current)
        let base = op.base.applied(to: current)
        let providerNewer = target.modifiedAt.map { $0 > op.queued_at } ?? false
        let winner: ConflictWinner = providerNewer ? .provider : .organizer
        var fields = Set<ReminderField>()
        var conflicts: [OpConflict] = []

        for field in op.fields.valueFields where !current.same(field, as: wanted) {
            if !op.base.has(field) || current.same(field, as: base) {
                fields.insert(field)
                continue
            }
            // Changed in Reminders since the organizer last saw it: last writer wins.
            conflicts.append(OpConflict(field: field, kept: winner, provider: current.display(field), organizer: wanted.display(field)))
            log.warn("reminders: op \(op.id) \(field.rawValue) changed on both sides; \(winner.rawValue) wins")
            if !providerNewer { fields.insert(field) }
        }

        var listId: String?
        if op.fields.has(.list), let to = op.fields.list_id, to != target.listId {
            let baseList = op.base.has(.list) ? op.base.list_id : nil
            if baseList != nil && baseList != target.listId {
                conflicts.append(OpConflict(field: .list, kept: winner, provider: target.listId, organizer: to))
                log.warn("reminders: op \(op.id) list changed on both sides; \(winner.rawValue) wins")
                if providerNewer { return write(target, ReminderChange(fields: fields, values: wanted), conflicts) }
            }
            if let problem = listProblem(to) { return .ack(.failure(problem)) }
            fields.insert(.list)
            listId = to
        }
        return write(target, ReminderChange(fields: fields, values: wanted, listId: listId), conflicts)
    }

    private func complete(_ op: ReminderOp, _ target: ReminderRecord, now: Date) -> Outcome {
        guard !target.values.completed else { return .ack(.success()) }
        var values = target.values
        values.completed = true
        return write(target, ReminderChange(fields: [.completed], values: values, completionDate: now), [])
    }

    private func uncomplete(_ op: ReminderOp, _ target: ReminderRecord) -> Outcome {
        guard target.values.completed else { return .ack(.success()) }
        if let done = target.completionDate, done > op.queued_at {
            log.warn("reminders: op \(op.id) uncomplete yields to a newer completion in Reminders")
            return .ack(.success(conflicts: [OpConflict(field: .completed, kept: .provider, provider: "true", organizer: "false")]))
        }
        var values = target.values
        values.completed = false
        return write(target, ReminderChange(fields: [.completed], values: values), [])
    }

    // MARK: helpers

    private func write(_ target: ReminderRecord, _ change: ReminderChange, _ conflicts: [OpConflict]) -> Outcome {
        guard !change.isEmpty else { return .ack(.success(conflicts: conflicts)) }
        if let problem = writeProblem(target.listId) { return .ack(.failure(problem)) }
        do {
            _ = try store.update(localId: target.localId, change: change)
            return .ack(.success(conflicts: conflicts))
        } catch {
            return .ack(.failure("\(error)"))
        }
    }

    private func resolve(_ op: ReminderOp) -> ReminderRecord? {
        if let local = createdInBatch[op.reminder_id], let r = store.reminder(localId: local) { return r }
        if let ext = op.external_id, let r = store.reminders(externalId: ext).first { return r }
        if let local = op.local_id, let r = store.reminder(localId: local) { return r }
        return nil
    }

    /// Why a reminder in `listId` cannot be written (a read-only list), or nil.
    private func writeProblem(_ listId: String) -> String? {
        guard let list = store.lists().first(where: { $0.id == listId }) else { return nil }
        return list.writable ? nil : "reminders list \(list.title) is read-only"
    }

    /// Why `listId` cannot receive a reminder, or nil.
    private func listProblem(_ listId: String) -> String? {
        guard let list = store.lists().first(where: { $0.id == listId }) else { return "reminders list \(listId) not found" }
        if !list.writable { return "reminders list \(list.title) is read-only" }
        return nil
    }
}
