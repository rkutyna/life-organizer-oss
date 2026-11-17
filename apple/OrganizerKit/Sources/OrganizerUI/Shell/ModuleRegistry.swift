import SwiftUI

/// Every module the app shows, in one list: its key, label, SF Symbol, order and screen.
///
/// The sidebar is built from this list. Each module's screen lives in its own folder,
/// `Features/<Module>/<Module>Screen.swift`, and the entry here names that type.
enum ModuleRegistry {
    static let all: [AppModule] = [
        AppModule(.calendar, "Calendar", systemImage: "calendar", order: 10, webPath: "/") { CalendarScreen() },
        AppModule(.reminders, "Reminders", systemImage: "checklist", order: 20, webPath: "/reminders") { RemindersScreen() },
        AppModule(.jobs, "Jobs", systemImage: "briefcase", order: 30, webPath: "/jobs") { JobsScreen() },
        AppModule(.mail, "Mail", systemImage: "envelope", order: 40, webPath: "/mail") { MailScreen() },
        AppModule(.settings, "Settings", systemImage: "gear", order: 100, webPath: "/settings") { SettingsScreen() },
    ].sorted { $0.order < $1.order }

    static func module(_ id: ModuleID) -> AppModule {
        all.first { $0.id == id }!
    }
}

/// A module's stable key (used for sidebar selection, customization and deep links).
nonisolated public enum ModuleID: String, CaseIterable, Hashable, Sendable {
    case calendar, reminders, jobs, mail, settings
}

struct AppModule: Identifiable {
    let id: ModuleID
    let label: String
    let systemImage: String
    /// Position in the sidebar, low first.
    let order: Int
    /// The matching page of the web app, for "Open in Web".
    let webPath: String
    private let makeScreen: () -> AnyView

    init<Screen: View>(
        _ id: ModuleID, _ label: String, systemImage: String, order: Int, webPath: String,
        @ViewBuilder screen: @escaping () -> Screen
    ) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.order = order
        self.webPath = webPath
        self.makeScreen = { AnyView(screen()) }
    }

    /// The module's root screen. It brings its own stack (`ModuleNavigationStack`).
    @ViewBuilder var screen: some View { makeScreen() }
}
