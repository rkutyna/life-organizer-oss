import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The Calendars sheet, behind the one "Calendars" button: each source with its color and its
/// freshness, switched on or off on this device (the choice is kept locally, not on the server).
struct CalendarSourcesSheet: View {
    @Bindable var store: CalendarStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sources, id: \.key) { source in
                        Toggle(isOn: binding(for: source.key)) {
                            label(for: source)
                        }
                        .accessibilityIdentifier("calendar.source.\(source.key)")
                    }
                } footer: {
                    Text("Switching a calendar off hides it on this device only. Nothing changes on the server.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .overlay {
                if store.sources.value?.isEmpty == true {
                    EmptyStateView("No calendars yet", systemImage: "calendar",
                                   message: "Calendars appear here once the server knows about them.")
                }
            }
            .navigationTitle("Calendars")
            .toolbar {
                if !store.hiddenSources.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Show All") { store.showAllSources() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 320, idealHeight: 420)
    }

    private var sources: [CalendarSourceOut] {
        store.sources.value ?? []
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { store.isShown(key) },
            set: { store.setShown(key, $0) }
        )
    }

    private func label(for source: CalendarSourceOut) -> some View {
        HStack(spacing: 10) {
            ColorDot(Palette.source(source.key, fallback: source.color), size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.label)
                if let reading = reading(for: source) {
                    Text(reading.text)
                        .font(.caption)
                        .foregroundStyle(color(for: reading.tone))
                }
            }
        }
    }

    /// How the source reads: live sources say so, mirrored ones say how fresh they are. "Not set up"
    /// is a calm state, not an alarm.
    private func reading(for source: CalendarSourceOut) -> CalendarFreshness.Reading? {
        if let freshness = source.freshness {
            return CalendarFreshness.reading(freshness)
        }
        return source.live ? CalendarFreshness.Reading(text: "live", tone: .quiet) : nil
    }

    private func color(for tone: CalendarFreshness.Tone) -> Color {
        switch tone {
        case .ok: Palette.status(.ok)
        case .stale: Palette.status(.stale)
        case .error: Palette.status(.error)
        case .quiet: Color.secondary
        }
    }
}
