import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The detail of one calendar item, in a sheet: its title, when, source, status and details. An owned
/// item opens in its module (Reminders, Jobs); a mirrored one is read-only here and opens on the
/// web, or in Calendar for an Apple event.
struct CalendarItemSheet: View {
    let entry: CalendarEntry

    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var item: CalendarItem { entry.item }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("calendar.item.title")
                        Text(CalendarLabels.when(entry))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                    LabeledContent("Source") {
                        SourceChip(item.sourceLabel, color: Palette.item(source: item.source, color: item.color))
                    }
                    if let status = CalendarLabels.status(item.status) {
                        LabeledContent("Status", value: status)
                    }
                }
                let details = CalendarDetails.rows(for: item)
                if !details.isEmpty {
                    Section("Details") {
                        ForEach(details) { detail in
                            LabeledContent(detail.label, value: detail.value)
                        }
                    }
                }
                actions
            }
            .navigationTitle(item.readOnly ? "Event" : "Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 480)
    }

    @ViewBuilder
    private var actions: some View {
        let appAction = CalendarLinks.appAction(for: item, entry: entry)
        let webURL = CalendarLinks.webURL(for: item, base: app.server.url)
        if appAction != nil || webURL != nil || item.readOnly {
            Section {
                if let appAction {
                    Button {
                        dismiss()
                        openURL(appAction.url)
                    } label: {
                        Label(appAction.title, systemImage: appAction.systemImage)
                    }
                    .accessibilityIdentifier("calendar.item.open")
                }
                if let webURL {
                    Link(destination: webURL) {
                        Label("Open in Web", systemImage: "safari")
                    }
                }
            } footer: {
                if item.readOnly {
                    Text("Read-only here. Edit it where it lives.")
                }
            }
        }
    }
}
