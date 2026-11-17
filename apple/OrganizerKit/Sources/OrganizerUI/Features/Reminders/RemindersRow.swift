import OrganizerAPI
import OrganizerCore
import SwiftUI

/// One row of the reminders list: the check, the title, a line of details (due, priority, notes,
/// list), and the sync mark while a change has not reached the provider.
struct RemindersRow: View {
    let reminder: ReminderOut
    let today: LocalDate
    /// The list chip (off when one list is being viewed).
    let showList: Bool
    /// The day in the due label (off in the Upcoming view, whose sections are days: the time only).
    var showsDay = true
    /// A reminder in a read-only list cannot be checked off.
    let locked: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onWithdraw: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RemindersDoneToggle(isDone: reminder.completed, disabled: locked, action: onToggle)
                .accessibilityIdentifier("reminders.toggle.\(reminder.id)")
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .strikethrough(reminder.completed, color: .secondary)
                    .foregroundStyle(reminder.completed ? .secondary : .primary)
                    .lineLimit(2)
                details
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("reminders.row.\(reminder.id)")
            Spacer(minLength: 8)
            RemindersSyncMark(reminder: reminder, onRetry: onRetry, onWithdraw: onWithdraw)
        }
        .padding(.vertical, 3)
    }

    /// Due, priority, notes and list; hidden when there is nothing to say.
    @ViewBuilder
    private var details: some View {
        let hasPriority = reminder.priority != nil && !reminder.completed
        if (reminder.dueDate != nil && (showsDay || reminder.dueTime != nil)) || hasPriority || !reminder.notes.isEmpty || showList || locked {
            HStack(spacing: 8) {
                if let due = reminder.dueDate, let label = dueLabel(due) {
                    Text(label)
                        .foregroundStyle(dueColor(due))
                        .monospacedDigit()
                        .accessibilityLabel("Due \(DayLabels.due(due, reminder.dueTime))")
                }
                if hasPriority, let label = RemindersPriority.label(reminder.priority) {
                    Label(label, systemImage: "flag.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(remindersPriorityColor(reminder.priority))
                        .accessibilityLabel("\(label) priority")
                }
                if !reminder.notes.isEmpty {
                    Image(systemName: "note.text")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Has notes")
                }
                if showList {
                    SourceChip(reminder.listTitle ?? "No list",
                               color: Palette.hex(reminder.listColor) ?? Palette.source("reminders"))
                }
                if locked {
                    Image(systemName: "lock")
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Read-only list")
                }
            }
            .font(.caption)
            .imageScale(.small)
            .lineLimit(1)
        }
    }

    private func dueLabel(_ due: LocalDate) -> String? {
        if showsDay { return DayLabels.due(due, reminder.dueTime) }
        return reminder.dueTime.map { DayLabels.time($0) }
    }

    private func dueColor(_ due: LocalDate) -> Color {
        guard !reminder.completed else { return .secondary }
        if due < today { return Palette.status(.overdue) }
        if due == today { return Palette.status(.today) }
        return .secondary
    }
}

/// The priority flag's color: high reads as urgent, low recedes (web: priorityColor).
func remindersPriorityColor(_ priority: Int?) -> Color {
    switch priority {
    case 1: Palette.status(.overdue)
    case 2: Palette.status(.stale)
    default: .secondary
    }
}

/// The round check button, shared by the rows and the edit sheet.
struct RemindersDoneToggle: View {
    let isDone: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isDone ? Palette.status(.ok) : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .help(disabled ? "This list is read-only" : (isDone ? "Mark not done" : "Mark done"))
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
        .accessibilityAddTraits(isDone ? .isSelected : [])
    }
}

/// A row's sync mark (web: ReminderBits.tsx): nothing when synced; a spinner while a change is on
/// its way; a clock while the Mac has not picked it up; a red mark for a change the provider refused,
/// whose popover offers Retry and Withdraw.
struct RemindersSyncMark: View {
    let reminder: ReminderOut
    let onRetry: () -> Void
    let onWithdraw: () -> Void

    @State private var showingFailure = false

    private var provider: String { RemindersProvider.name(reminder.source) }

    var body: some View {
        switch reminder.sync.state {
        case .synced, .unknown:
            EmptyView()
        case .syncing:
            ProgressView()
                .controlSize(.small)
                .help("Saving to \(provider)")
                .accessibilityLabel("Saving to \(provider)")
        case .waitingForDevice:
            Label("waiting for Mac", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(waitingHelp)
                .accessibilityLabel("Waiting for the Mac")
        case .failed:
            Button {
                showingFailure = true
            } label: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Palette.status(.error))
            }
            .buttonStyle(.plain)
            .help("\(provider) did not take a change")
            .accessibilityLabel("\(provider) did not take a change. Show details")
            .accessibilityIdentifier("reminders.failed.\(reminder.id)")
            .popover(isPresented: $showingFailure, arrowEdge: .trailing) {
                RemindersFailedActions(reminder: reminder, onRetry: {
                    showingFailure = false
                    onRetry()
                }, onWithdraw: {
                    showingFailure = false
                    onWithdraw()
                })
                .padding()
                .frame(width: 280)
            }
        }
    }

    private var waitingHelp: String {
        guard let since = reminder.sync.waitingSince else { return "Applies when your Mac is awake." }
        return "Queued \(Freshness.age(of: since)). Applies when your Mac is awake and the helper is running."
    }
}

/// The provider's refusal and the two ways out: try the change again, or drop it.
struct RemindersFailedActions: View {
    let reminder: ReminderOut
    let onRetry: () -> Void
    let onWithdraw: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(RemindersProvider.name(reminder.source)) did not take this change.",
                  systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.status(.error))
                .fixedSize(horizontal: false, vertical: true)
            if let error = reminder.sync.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                    .accessibilityIdentifier("reminders.retry")
                Button("Withdraw", systemImage: "arrow.uturn.backward", role: .destructive, action: onWithdraw)
                    .accessibilityIdentifier("reminders.withdraw")
            }
            .controlSize(.small)
            .disabled(reminder.failedOps.isEmpty)
        }
    }
}
