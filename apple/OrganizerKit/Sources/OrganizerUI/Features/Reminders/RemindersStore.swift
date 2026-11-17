import Foundation
import Observation
import OrganizerAPI
import OrganizerCore

/// The Reminders screen's state: every reminder (open, and completed in the last 30 days), the
/// lists, and the module's sync status, one `Resource` each.
///
/// Every write goes through the REST API, which queues an op for the provider and answers with the
/// reminder as shown (the op applied on top, `sync` saying where it stands); that answer replaces
/// the row. Completing is optimistic: the row changes at once and goes back if the server refuses.
/// While a change is on its way the screen polls every 5 seconds, otherwise every 30.
@MainActor
@Observable
final class RemindersStore {
    let reminders: Resource<[ReminderOut]>
    let lists: Resource<[ReminderListOut]>
    let status: Resource<ReminderStatusOut>

    /// A failure (the server's message) or a confirmation, shown by `.notices`.
    var notice: Notice?
    /// Sync Now is running.
    private(set) var isSyncing = false
    /// Reminders with a completion on its way, so a second click waits for the first.
    private(set) var toggling: Set<Int> = []
    /// The last `QuickAddFocus.requests` the screen honored (kept here so it survives the screen).
    var focusRequestsSeen = 0

    @ObservationIgnored let client: OrganizerClient
    @ObservationIgnored let today: () -> LocalDate

    init(client: OrganizerClient, today: @escaping () -> LocalDate = { LocalDate.today() }) {
        self.client = client
        self.today = today
        reminders = Resource(API.Reminders.listReminders(includeCompleted: true), client: client)
        lists = Resource(API.Reminders.reminderLists(), client: client)
        status = Resource(API.Reminders.remindersStatus(), client: client)
    }

    // MARK: Loading

    /// The screen needs the reminders; the lists and status only add to it.
    var loadStatus: LoadStatus {
        LoadStatus(primary: reminders.state.status, secondary: [lists.state.status, status.state.status])
    }

    func refresh() async {
        async let reminders: Void = self.reminders.refresh()
        async let lists: Void = self.lists.refresh()
        async let status: Void = self.status.refresh()
        _ = await (reminders, lists, status)
    }

    /// One tick of the poll: the reminders and the status; the lists only when nothing is moving.
    func poll() async {
        async let reminders: Void = self.reminders.refresh()
        async let status: Void = self.status.refresh()
        if !isBusy { await lists.refresh() }
        _ = await (reminders, status)
    }

    /// A change is on its way somewhere: a reminder is syncing or the queue is not empty.
    var isBusy: Bool {
        (reminders.value ?? []).contains(where: \.isSyncInFlight) || (status.value?.pendingOps ?? 0) > 0
    }

    var pollInterval: Duration { isBusy ? .seconds(5) : .seconds(30) }

    // MARK: Reads

    func sections(for scope: RemindersScope) -> [RemindersSection] {
        RemindersSections.make(reminders.value ?? [], scope: scope, today: today())
    }

    func openCount(for scope: RemindersScope) -> Int {
        if case .list(let id) = scope, reminders.value == nil {
            return lists.value?.list(id)?.openCount ?? 0
        }
        return RemindersSections.openCount(reminders.value ?? [], scope: scope, today: today())
    }

    var allLists: [ReminderListOut] { lists.value ?? [] }
    var listGroups: [RemindersListGroup] { RemindersListGroup.groups(allLists) }
    var writableLists: [ReminderListOut] { allLists.filter(\.writable) }

    func list(_ id: String?) -> ReminderListOut? { allLists.list(id) }

    func reminder(_ id: Int) -> ReminderOut? {
        reminders.value?.first { $0.id == id }
    }

    /// A reminder in a read-only list cannot be checked off or edited.
    func isLocked(_ reminder: ReminderOut) -> Bool {
        allLists.isReadOnly(reminder.listId)
    }

    /// No list at all: neither Google Tasks nor the Mac helper is set up.
    var hasNoSources: Bool {
        lists.value?.isEmpty == true && (reminders.value ?? []).isEmpty
    }

    /// The reminder with this id: the loaded copy, else fetched (a deep link to one not loaded).
    func find(_ id: Int) async -> ReminderOut? {
        if reminders.value == nil { await reminders.refresh() }
        if let known = reminder(id) { return known }
        do {
            return try await client.reminders.get(id: id)
        } catch {
            notice = .failure("Couldn't open the reminder", error)
            return nil
        }
    }

    // MARK: Writes

    /// Checks a reminder off, or back on, at once; puts it back if the server refuses.
    func toggle(_ reminder: ReminderOut) async {
        guard !isLocked(reminder), !toggling.contains(reminder.id) else { return }
        let done = !reminder.completed
        toggling.insert(reminder.id)
        defer { toggling.remove(reminder.id) }
        let before = reminders.modify { rows in
            guard let index = rows.firstIndex(where: { $0.id == reminder.id }) else { return }
            rows[index].completed = done
            rows[index].completedAt = done ? Date() : nil
            rows[index].sync.state = .syncing
        }
        do {
            let updated = try await client.reminders.setDone(id: reminder.id, done)
            replace(updated)
            await status.refresh()
        } catch {
            reminders.restore(before)
            notice = .failure(done ? "Couldn't complete “\(reminder.title)”" : "Couldn't reopen “\(reminder.title)”", error)
        }
    }

    /// Adds a reminder to `list`. Returns whether it was added (the field clears only then).
    func add(_ plan: RemindersQuickAddPlan, to list: ReminderListOut?) async -> Bool {
        guard !plan.fields.title.isEmpty else { return false }
        do {
            let created = try await client.reminders.create(plan.request(listID: list?.id))
            replace(created)
            await status.refresh()
            return true
        } catch {
            notice = .failure("Couldn't add the reminder", error)
            return false
        }
    }

    /// Sends the edit sheet's changes. Returns the server's refusal, which the sheet shows with the
    /// edits kept; nil when saved.
    func save(_ reminder: ReminderOut, _ changes: ReminderUpdate) async -> APIError? {
        do {
            let updated = try await client.reminders.update(id: reminder.id, changes)
            replace(updated)
            await status.refresh()
            return nil
        } catch {
            return APIError(error)
        }
    }

    /// Queues the reminder's failed changes again.
    func retryFailed(_ reminder: ReminderOut) async {
        await eachFailedOp(of: reminder, failure: "Couldn't retry the change") { try await self.client.reminders.retry(opID: $0) }
    }

    /// Drops the reminder's failed changes. A create the provider never got takes the reminder away.
    func withdrawFailed(_ reminder: ReminderOut) async {
        await eachFailedOp(of: reminder, failure: "Couldn't withdraw the change") { try await self.client.reminders.withdraw(opID: $0) }
    }

    private func eachFailedOp(of reminder: ReminderOut, failure: String, _ run: (Int) async throws -> Void) async {
        for op in reminder.failedOps {
            do {
                try await run(op.id)
            } catch {
                notice = .failure(failure, error)
                break
            }
        }
        async let reminders: Void = self.reminders.refresh()
        async let status: Void = self.status.refresh()
        _ = await (reminders, status)
    }

    /// Polls Google Tasks now (Apple Reminders arrives whenever the Mac helper pushes), then reloads
    /// everything. A Google account that failed is reported with its error.
    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let outcomes = try await client.reminders.syncNow()
            if let failed = outcomes.first(where: { !$0.ok }) {
                let message = failed.error ?? "The Google account did not answer."
                notice = .failure("Sync failed", APIError.server(status: 502, message: message))
            }
        } catch {
            notice = .failure("Sync failed", error)
        }
        await refresh()
    }

    /// Puts the server's copy of a reminder in place of the one on screen (or adds a new one).
    private func replace(_ updated: ReminderOut) {
        reminders.modify { rows in
            if let index = rows.firstIndex(where: { $0.id == updated.id }) {
                rows[index] = updated
            } else {
                rows.append(updated)
            }
        }
    }
}
