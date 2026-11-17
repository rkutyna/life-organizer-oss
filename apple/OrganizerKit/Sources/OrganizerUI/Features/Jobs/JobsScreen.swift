import SwiftUI

/// Placeholder until the Jobs screen lands.
struct JobsScreen: View {
    var body: some View {
        ModuleNavigationStack {
            EmptyStateView("Jobs", systemImage: "hammer")
                .navigationTitle("Jobs")
        }
    }
}
