import OrganizerAPI
import OrganizerCore
import SwiftUI

/// Edit one reminder: title, notes, due date and time, priority and list. Save sends one PATCH
/// with only the fields that changed; a refusal (409, 422) is shown here with the edits kept. A list
/// without times or priorities (Google Tasks) hides those fields; a read-only list locks them all.
/// There is no delete: the organizer never deletes a reminder.
struct RemindersEditSheet: View {
    let store: RemindersStore
    /// The copy the sheet opened with, used if the reminder is not in the loaded list.
    let opened: ReminderOut

    @Environment(\.dismiss) private var dismiss
    @State private var draft: RemindersDraft
    @State private var saving = false
    @State private var error: APIError?

    init(store: RemindersStore, reminder: ReminderOut) {
        self.store = store
        self.opened = reminder
        _draft = State(initialValue: RemindersDraft(reminder))
    }

    /// The live copy: a poll or a Retry may have changed it since the sheet opened.
    private var current: ReminderOut { store.reminder(opened.id) ?? opened }
    private var list: ReminderListOut? { store.list(draft.listID) ?? store.list(current.listId) }
    private var supportsTime: Bool { list?.supportsTime ?? (current.source != .google) }
    private var supportsPriority: Bool { list?.supportsPriority ?? (current.source != .google) }
    private var locked: Bool { store.isLocked(current) }
    private var provider: String { RemindersProvider.name(current.source) }

    /// A reminder moves only within its account: the writable lists of the same account, plus its
    /// current list so it still shows.
    private var listChoices: [ReminderListOut] {
        store.allLists.filter { candidate in
            candidate.id == current.listId
                || (candidate.writable && candidate.source.rawValue == current.source.rawValue
                    && candidate.accountId == current.accountId)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    syncNote
                } footer: {
                    if locked {
                        Text("This list is read-only in \(provider), so its reminders cannot be changed here.")
                    }
                }

                Section {
                    TextField("Title", text: $draft.title, prompt: Text("Title"), axis: .vertical)
                        .labelsHidden()
                        .font(.headline)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("reminders.edit.title")
                    TextField("Notes", text: $draft.notes, prompt: Text("Notes"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...10)
                        .accessibilityIdentifier("reminders.edit.notes")
                }
                .disabled(locked || saving)

                Section {
                    Toggle("Due Date", isOn: $draft.hasDate.animation())
                        .accessibilityIdentifier("reminders.edit.hasDate")
                    if draft.hasDate {
                        DatePicker("Day", selection: $draft.date, displayedComponents: .date)
                        if supportsTime {
                            Toggle("Due Time", isOn: $draft.hasTime.animation())
                                .accessibilityIdentifier("reminders.edit.hasTime")
                            if draft.hasTime {
                                DatePicker("Time", selection: $draft.time, displayedComponents: .hourAndMinute)
                            }
                        }
                    }
                } footer: {
                    if !supportsTime || !supportsPriority {
                        Text("\(provider) keeps a due date but no time or priority.")
                    }
                }
                .disabled(locked || saving)

                Section {
                    if supportsPriority {
                        Picker("Priority", selection: $draft.priority) {
                            Text("None").tag(Int?.none)
                            ForEach(RemindersPriority.options, id: \.value) { option in
                                Text(option.label).tag(Int?.some(option.value))
                            }
                        }
                        .accessibilityIdentifier("reminders.edit.priority")
                    }
                    Picker("List", selection: $draft.listID) {
                        ForEach(listChoices, id: \.id) { choice in
                            Text(choice.title).tag(String?.some(choice.id))
                        }
                        if draft.listID == nil { Text("No list").tag(String?.none) }
                    }
                    .disabled(listChoices.count < 2)
                    .accessibilityIdentifier("reminders.edit.list")
                }
                .disabled(locked || saving)

                Section {
                    OpenInWebLink(path: "/reminders?reminder=\(current.id)")
                } footer: {
                    Text(footerText)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reminder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(locked || draft.trimmedTitle.isEmpty)
                            .accessibilityIdentifier("reminders.edit.save")
                    }
                }
            }
            .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error?.message ?? "")
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 540, idealHeight: 600)
    }

    @ViewBuilder
    private var syncNote: some View {
        switch current.sync.state {
        case .synced, .unknown:
            Label("Synced with \(provider)", systemImage: "checkmark.icloud")
                .foregroundStyle(.secondary)
        case .syncing:
            Label {
                Text("Saving to \(provider)")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .foregroundStyle(.secondary)
        case .waitingForDevice:
            VStack(alignment: .leading, spacing: 4) {
                Label("Waiting for Mac", systemImage: "clock")
                Text(waitingText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            RemindersFailedActions(
                reminder: current,
                onRetry: { Task { await store.retryFailed(current) } },
                onWithdraw: { Task { await store.withdrawFailed(current) } }
            )
        }
    }

    private var waitingText: String {
        let since = current.sync.waitingSince.map { "Queued \(Freshness.age(of: $0)). " } ?? ""
        return since + "The change applies when your Mac is awake and the helper is running."
    }

    private var footerText: String {
        var parts = ["\(current.listTitle ?? "No list") · \(provider)"]
        if let modified = current.modifiedAt {
            parts.append("last changed there \(Freshness.age(of: modified))")
        }
        return parts.joined(separator: " · ")
    }

    private func save() {
        let original = RemindersDraft(opened)
        let changes = draft.changes(from: original, supportsTime: supportsTime, supportsPriority: supportsPriority)
        guard changes != ReminderUpdate() else {
            dismiss()
            return
        }
        saving = true
        Task {
            let failure = await store.save(current, changes)
            saving = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
