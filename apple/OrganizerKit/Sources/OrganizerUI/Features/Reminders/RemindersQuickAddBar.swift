import OrganizerAPI
import OrganizerCore
import SwiftUI

/// One line to add a reminder, with natural-language dates ("tomorrow 3pm", "next fri") and "!1"
/// to "!3" for priority, and a live preview of what was understood (web: QuickAdd.tsx). The target
/// list is the one being viewed, else the one last picked here (per device). A list without times
/// or priorities (Google Tasks) drops them, and the preview says so. Return adds; Escape clears.
struct RemindersQuickAddBar: View {
    @Bindable var store: RemindersStore
    /// The list on screen, if one is: new reminders go there.
    let viewingListID: String?
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    @AppStorage("reminders.addTo") private var remembered = ""
    @State private var isAdding = false

    private var target: ReminderListOut? {
        RemindersTarget.resolve(store.allLists, viewing: viewingListID, remembered: remembered)
    }

    private var plan: RemindersQuickAddPlan? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return RemindersQuickAddPlan(QuickAddParser.parse(trimmed), list: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(plan == nil ? Color.secondary : Palette.primary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                TextField("New reminder", text: $text,
                          prompt: Text(target == nil
                                       ? "Connect Google Tasks or the Mac helper to add reminders"
                                       : "Add a reminder — try “Call the plumber tomorrow 3pm !1”"))
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .onSubmit(submit)
                    .onExitCommand { text = "" }
                    .disabled(isAdding || target == nil)
                    .accessibilityLabel("New reminder")
                    .accessibilityIdentifier("reminders.quickAdd")
                if !store.writableLists.isEmpty {
                    listMenu
                }
                if isAdding {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if let plan, plan.hasPreview {
                Divider()
                preview(plan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .transition(.opacity)
            }
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused.wrappedValue ? Palette.primary.opacity(0.6) : Color(nsColor: .separatorColor),
                              lineWidth: focused.wrappedValue ? 1.5 : 0.5)
        }
        .animation(.snappy(duration: 0.15), value: plan?.hasPreview)
    }

    private var listMenu: some View {
        Menu {
            Picker("Add to", selection: Binding(get: { target?.id ?? "" }, set: { remembered = $0 })) {
                ForEach(RemindersListGroup.groups(store.writableLists)) { group in
                    Section(group.title) {
                        ForEach(group.lists, id: \.id) { list in
                            Text(list.title).tag(list.id)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                if let target {
                    ColorDot(Palette.hex(target.color) ?? Palette.source("reminders"))
                    Text(target.title)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isAdding)
        .help("The list a new reminder goes into")
        .accessibilityLabel("Add to list")
        .accessibilityIdentifier("reminders.quickAdd.list")
    }

    /// What was understood: the title, the day and time, the priority, and what this list leaves out.
    private func preview(_ plan: RemindersQuickAddPlan) -> some View {
        HStack(spacing: 10) {
            Text(plan.fields.title)
                .lineLimit(1)
                .layoutPriority(0)
            if let due = plan.fields.dueDate {
                Label(DayLabels.due(due, plan.fields.dueTime), systemImage: "calendar")
                    .foregroundStyle(Palette.source("reminders"))
                    .fontWeight(.medium)
                    .fixedSize()
                    .layoutPriority(2)
                Text(DayLabels.long(due))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if let priority = plan.fields.priority, let label = RemindersPriority.label(priority) {
                Label(label, systemImage: "flag.fill")
                    .foregroundStyle(remindersPriorityColor(priority))
                    .fixedSize()
                    .layoutPriority(2)
            }
            if let note = plan.droppedNote(provider: target.map { RemindersProvider.name($0.source) } ?? "This list") {
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            Text("Return to add")
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("reminders.quickAdd.preview")
    }

    private func submit() {
        guard let plan, !plan.fields.title.isEmpty, !isAdding else { return }
        isAdding = true
        Task {
            if await store.add(plan, to: target) {
                text = ""
            }
            isAdding = false
            focused.wrappedValue = true
        }
    }
}
