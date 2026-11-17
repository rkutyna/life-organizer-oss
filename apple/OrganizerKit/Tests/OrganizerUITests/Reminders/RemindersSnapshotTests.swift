import AppKit
import OrganizerAPI
import OrganizerCore
import SwiftUI
import Testing

@testable import OrganizerUI

/// Draws the Reminders screen from the demo server: the Today view, All, one list, the edit sheet
/// and the status panel. Reads only.
@Suite(.enabled(if: Snapshot.enabled))
@MainActor
struct RemindersSnapshotTests {
    @Test func renderReminders() async throws {
        let app = try Snapshot.app()
        let store = app.store { RemindersStore(client: $0) }
        await store.refresh()
        let size = CGSize(width: 1100, height: 720)

        for (scope, name) in [(RemindersScope.today, "today"), (.all, "all"), (.upcoming, "upcoming")] {
            UserDefaults.standard.set(scope.storageKey, forKey: "reminders.scope")
            try Snapshot.render(RemindersScreen().environment(app), size: size, name: "mac-reminders-\(name)")
        }
        if let list = store.allLists.first {
            UserDefaults.standard.set(RemindersScope.list(list.id).storageKey, forKey: "reminders.scope")
            try Snapshot.render(RemindersScreen().environment(app), size: size, name: "mac-reminders-list")
        }
        UserDefaults.standard.set(RemindersScope.today.storageKey, forKey: "reminders.scope")

        if let reminder = store.reminders.value?.first(where: { $0.dueTime != nil }) ?? store.reminders.value?.first {
            try Snapshot.render(RemindersEditSheet(store: store, reminder: reminder).environment(app),
                                size: CGSize(width: 480, height: 600), name: "mac-reminders-edit")
        }
        try Snapshot.render(RemindersStatusPanel(store: store).environment(app),
                            size: CGSize(width: 320, height: 220), name: "mac-reminders-status")
    }

    /// The quick-add bar with a typed line, to see the live preview.
    @Test func renderQuickAddPreview() async throws {
        let app = try Snapshot.app()
        let store = app.store { RemindersStore(client: $0) }
        await store.refresh()
        try Snapshot.render(RemindersQuickAddPreviewHost(store: store, text: "Call the plumber tomorrow 3pm !1").environment(app),
                            size: CGSize(width: 760, height: 120), name: "mac-reminders-quickadd")
    }
}

/// Hosts the quick-add bar with text already typed (a `FocusState` needs a view to live in).
private struct RemindersQuickAddPreviewHost: View {
    let store: RemindersStore
    @State var text: String
    @FocusState private var focused: Bool

    var body: some View {
        RemindersQuickAddBar(store: store, viewingListID: nil, text: $text, focused: $focused)
            .padding()
    }
}
