import SwiftUI

/// Placeholder until the Reminders screen lands.
struct RemindersScreen: View {
    var body: some View {
        ModuleNavigationStack {
            EmptyStateView("Reminders", systemImage: "hammer")
                .navigationTitle("Reminders")
        }
    }
}
