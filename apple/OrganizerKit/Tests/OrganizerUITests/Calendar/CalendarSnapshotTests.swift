import AppKit
import OrganizerCore
import SwiftUI
import Testing

@testable import OrganizerUI

@Suite(.enabled(if: Snapshot.enabled))
@MainActor
struct CalendarSnapshotTests {
    @Test func renderCalendar() async throws {
        let app = try Snapshot.app()
        UserDefaults.standard.set(CalendarViewMode.week.rawValue, forKey: "calendar.view")
        let calendar = app.store { CalendarStore(client: $0) }
        await calendar.prepare()
        await calendar.load(calendar.windows(for: .week))
        try Snapshot.render(CalendarScreen().environment(app), size: CGSize(width: 1100, height: 760), name: "mac-calendar")
        if let entry = calendar.entries(in: calendar.windows(for: .week)).first(where: { $0.item.source.hasPrefix("jobs") }) {
            try Snapshot.render(CalendarItemSheet(entry: entry).environment(app), size: CGSize(width: 460, height: 520), name: "mac-calendar-item")
        }
        try Snapshot.render(CalendarSourcesSheet(store: calendar).environment(app), size: CGSize(width: 420, height: 520), name: "mac-calendar-sources")
    }
}
