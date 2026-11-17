import SwiftUI

/// Placeholder until the Mail screen lands.
struct MailScreen: View {
    var body: some View {
        ModuleNavigationStack {
            EmptyStateView("Mail", systemImage: "hammer")
                .navigationTitle("Mail")
        }
    }
}
