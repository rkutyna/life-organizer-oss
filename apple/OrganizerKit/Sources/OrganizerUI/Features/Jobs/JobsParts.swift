import OrganizerAPI
import OrganizerCore
import SwiftUI

/// A small tinted capsule in a token color: a status, an attendance.
struct JobsChip: View {
    let text: String
    let tone: Color

    init(_ text: String, tone: Color) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .font(.caption.weight(.medium))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.opacity(0.14), in: Capsule())
    }
}

/// An application's status in its kind's color, named as the server's status list names it.
struct JobsStatusChip: View {
    let store: JobsStore
    let status: String

    var body: some View {
        JobsChip(store.label(status), tone: JobsTone.kind(store.kind(status)))
    }
}

/// A due day in red when past, blue when today.
struct JobsDueText: View {
    let action: String
    let due: LocalDate?

    var body: some View {
        Text(JobsFormat.nextAction(action, due: due))
            .foregroundStyle(due == nil ? Color.primary : JobsTone.due(JobsFormat.due(due)))
            .lineLimit(1)
    }
}

/// A list section's bar above its table: filters on the leading side, a count and actions on
/// the trailing side.
struct JobsFilterBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// A search field for a filter bar.
struct JobsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: 260)
    }
}

/// A labelled row in a record screen; hidden when the value is empty.
struct JobsFieldRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if !value.isEmpty {
            LabeledContent(label) {
                Text(value)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

/// A link row: the text opens in the browser when it is a web address.
struct JobsLinkRow: View {
    let label: String
    let value: String

    var body: some View {
        if !value.isEmpty {
            LabeledContent(label) {
                if let url = JobsFormat.webURL(value) {
                    Link(value, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(value).textSelection(.enabled)
                }
            }
        }
    }
}

/// Notes as a block of selectable text, or a quiet line when there are none.
struct JobsNotesSection: View {
    let notes: String

    var body: some View {
        Section("Notes") {
            if notes.isEmpty {
                Text("No notes")
                    .foregroundStyle(.secondary)
            } else {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Tags as small capsules.
struct JobsTagsRow: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            LabeledContent("Tags") {
                HStack(spacing: 4) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }
}

// MARK: - Form fields

/// A day that may be empty: a checkbox, and the picker when it is set.
struct JobsOptionalDateField: View {
    let label: String
    @Binding var day: LocalDate?
    var defaultDay: LocalDate = .today()

    var body: some View {
        LabeledContent(label) {
            HStack {
                Toggle(isOn: Binding(
                    get: { day != nil },
                    set: { day = $0 ? (day ?? defaultDay) : nil }
                )) {
                    Text(label)
                }
                .labelsHidden()
                if day != nil {
                    DatePicker(label, selection: JobsBindings.date($day, fallback: defaultDay), displayedComponents: .date)
                        .labelsHidden()
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A time of day that may be empty.
struct JobsOptionalTimeField: View {
    let label: String
    @Binding var time: LocalTime?
    var defaultTime = LocalTime(hour: 9, minute: 0)

    var body: some View {
        LabeledContent(label) {
            HStack {
                Toggle(isOn: Binding(
                    get: { time != nil },
                    set: { time = $0 ? (time ?? defaultTime) : nil }
                )) {
                    Text(label)
                }
                .labelsHidden()
                if time != nil {
                    DatePicker(label, selection: JobsBindings.time($time, fallback: defaultTime), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                } else {
                    Text("None").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Bridges the API's wall-clock values to `DatePicker`'s `Date`, in the device's calendar.
enum JobsBindings {
    static func date(_ day: Binding<LocalDate?>, fallback: LocalDate) -> Binding<Date> {
        Binding(
            get: { (day.wrappedValue ?? fallback).date(in: .current) },
            set: { day.wrappedValue = LocalDate($0, calendar: .current) }
        )
    }

    static func date(_ day: Binding<LocalDate>) -> Binding<Date> {
        Binding(
            get: { day.wrappedValue.date(in: .current) },
            set: { day.wrappedValue = LocalDate($0, calendar: .current) }
        )
    }

    static func time(_ time: Binding<LocalTime?>, fallback: LocalTime) -> Binding<Date> {
        let anchor = LocalDate(year: 2000, month: 1, day: 1)
        return Binding(
            get: { (time.wrappedValue ?? fallback).date(on: anchor, calendar: .current) },
            set: { time.wrappedValue = LocalTime($0, calendar: .current) }
        )
    }

    /// Minutes as text: blank is none.
    static func minutes(_ minutes: Binding<Int?>) -> Binding<String> {
        Binding(
            get: { minutes.wrappedValue.map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                minutes.wrappedValue = digits.isEmpty ? nil : Int(digits)
            }
        )
    }
}

/// A company picked from the tracker's companies, or none (when `allowsNone`).
struct JobsCompanyPicker: View {
    let store: JobsStore
    @Binding var companyID: Int?
    var allowsNone = false
    /// The name to show for the current company before the list has loaded.
    var currentName: String?

    var body: some View {
        Picker("Company", selection: $companyID) {
            if allowsNone {
                Text("None").tag(Int?.none)
            }
            if let companies = store.companies.value {
                ForEach(companies) { company in
                    Text(company.name).tag(Int?.some(company.id))
                }
            } else if let companyID, let currentName {
                Text(currentName).tag(Int?.some(companyID))
            }
        }
        .task { await store.loadCompanies() }
    }
}

/// Cancel and Save for an edit sheet, and the server's message when a save was refused.
struct JobsSheetScaffold<Content: View>: View {
    let title: String
    let saveTitle: String
    let canSave: Bool
    let save: () async throws -> Void
    let content: Content

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?

    init(title: String, saveTitle: String, canSave: Bool, save: @escaping () async throws -> Void,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.saveTitle = saveTitle
        self.canSave = canSave
        self.save = save
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            Form {
                content
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Palette.status(.error))
                            .accessibilityIdentifier("jobs.sheet.error")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        Task { await run() }
                    }
                    .disabled(!canSave || saving)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .disabled(saving)
        }
        .frame(minWidth: 460, idealWidth: 500, minHeight: 360, idealHeight: 560)
    }

    private func run() async {
        saving = true
        defer { saving = false }
        do {
            try await save()
            dismiss()
        } catch {
            self.error = APIError(error).message
        }
    }
}
