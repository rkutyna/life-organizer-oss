import Foundation

/// The server calls the Reminders sync makes besides the snapshot push.
public protocol RemindersServer: AnyObject {
    /// Pending ops in queue order; nil when the server has no such endpoint (404).
    func fetchReminderOps() async throws -> [ReminderOp]?
    /// Records one op's result. false: the op is gone (withdrawn in the organizer, 404).
    func ackReminderOp(_ id: Int, _ ack: OpAck) async throws -> Bool
}

/// One Reminders cycle, in this order so the snapshot always reflects what was just written:
/// 1. apply the organizer's queued ops and ack each (`ReminderOpsApplier`);
/// 2. collect the snapshot (`RemindersCollector`), pushed by the runtime.
/// The daemon runs one cycle at a time, so a snapshot never sees a half-done write.
public final class RemindersSync: @unchecked Sendable {
    public struct StepResult: Equatable, Sendable {
        public var summary: String
        public var changed: Bool
        public var failed: Bool
    }

    private let store: ReminderStore
    private let completedDays: Int
    private let statePath: String
    private let lock = NSLock()
    private var state: RemindersState

    public init(store: ReminderStore, completedDays: Int, statePath: String) {
        self.store = store
        self.completedDays = completedDays
        self.statePath = statePath
        state = RemindersState.load(path: statePath)
    }

    public var currentState: RemindersState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    private func setState(_ s: RemindersState) {
        lock.lock()
        state = s
        lock.unlock()
        s.save(path: statePath)
    }

    public func applyOps(server: RemindersServer, now: Date = Date()) async -> StepResult {
        let ops: [ReminderOp]
        do {
            guard let fetched = try await server.fetchReminderOps() else {
                return StepResult(summary: "ops endpoint not found (HTTP 404)", changed: false, failed: false)
            }
            ops = fetched
        } catch {
            return StepResult(summary: "error: \(error)", changed: false, failed: true)
        }
        if ops.isEmpty { return StepResult(summary: "no ops", changed: false, failed: false) }

        var working = currentState
        working.prune(now: now)
        let applier = ReminderOpsApplier(store: store, state: working)
        var blocked = Set<Int>()
        var applied = 0, failed = 0, later = 0, gone = 0
        var stopped: String?
        for op in ops {
            if Task.isCancelled { stopped = "cancelled"; break }
            if blocked.contains(op.reminder_id) { later += 1; continue }
            switch applier.apply(op, now: now) {
            case .later(let why):
                log.info("reminders: op \(op.id) left for later: \(why)")
                blocked.insert(op.reminder_id)
                later += 1
            case .ack(let ack):
                setState(applier.state)  // a create is remembered before its ack goes out
                if ack.ok { applied += 1 } else { failed += 1; log.warn("reminders: op \(op.id) failed: \(ack.error ?? "")") }
                do {
                    if try await !server.ackReminderOp(op.id, ack) { gone += 1 }
                } catch {
                    // Stop here: the rest stay pending and are re-sent; re-applying is harmless.
                    stopped = "ack \(op.id) failed: \(error)"
                }
            }
            if stopped != nil { break }
        }
        setState(applier.state)
        var summary = "ops \(ops.count): applied \(applied), failed \(failed), later \(later)"
        if gone > 0 { summary += ", withdrawn \(gone)" }
        if let stopped { summary += "; \(stopped)" }
        return StepResult(summary: summary, changed: applied + failed > 0, failed: stopped != nil)
    }

    public func collect(now: Date = Date()) async throws -> RemindersBody {
        try await RemindersCollector(store: store, completedDays: completedDays).collect(now: now)
    }
}
