import AppKit
import OrganizerAPI
import OrganizerCore
import SwiftUI
import Testing

@testable import OrganizerUI

/// Draws the Jobs screen from the local demo server: every section, the record screens and the
/// sheets. Reads only. See `Snapshot` for how to run it.
@Suite(.enabled(if: Snapshot.enabled))
@MainActor
struct JobsSnapshotTests {
    static let size = CGSize(width: 1100, height: 720)

    @Test func renderJobs() async throws {
        let app = try Snapshot.app()
        let store = app.store { JobsStore(client: $0) }
        await store.prepare()

        for section in JobsSection.allCases {
            await store.load(section)
            store.section = section
            try Snapshot.render(JobsScreen().environment(app), size: Self.size, name: "mac-jobs-\(section.rawValue)")
        }

        // Records, pushed on their section as a deep link would.
        if let application = store.applications.value?.first(where: { store.kind($0.status) == .active && $0.status != "applied" })
            ?? store.applications.value?.first {
            await store.applicationDetail(application.id).load()
            store.go(to: JobsLocation(section: .applications, route: .application(application.id)))
            try Snapshot.render(JobsScreen().environment(app), size: CGSize(width: 1100, height: 900), name: "mac-jobs-application")
            try Snapshot.render(JobsStatusSheet(store: store, application: application).environment(app),
                                size: CGSize(width: 500, height: 440), name: "mac-jobs-sheet-status")
            try Snapshot.render(JobsApplicationSheet(store: store, original: application).environment(app),
                                size: CGSize(width: 500, height: 640), name: "mac-jobs-sheet-application")
        }
        if let lead = store.leads.value?.first {
            await store.applicationDetail(lead.id).load()
            store.go(to: JobsLocation(section: .leads, route: .application(lead.id)))
            try Snapshot.render(JobsScreen().environment(app), size: Self.size, name: "mac-jobs-lead")
            try Snapshot.render(JobsDropSheet(store: store, lead: lead).environment(app),
                                size: CGSize(width: 500, height: 280), name: "mac-jobs-sheet-drop")
        }
        if let contact = store.contacts.value?.first(where: { $0.company != nil }) {
            await store.contactRead(contact.id).refresh()
            store.go(to: JobsLocation(section: .contacts, route: .contact(contact.id)))
            try Snapshot.render(JobsScreen().environment(app), size: Self.size, name: "mac-jobs-contact")
            await store.loadCompanies()
            try Snapshot.render(JobsContactSheet(store: store, original: contact).environment(app),
                                size: CGSize(width: 500, height: 680), name: "mac-jobs-sheet-contact")
        }
        if let interview = store.interviews.value?.first {
            await store.interviewRead(interview.id).refresh()
            store.go(to: JobsLocation(section: .interviews, route: .interview(interview.id)))
            try Snapshot.render(JobsScreen().environment(app), size: Self.size, name: "mac-jobs-interview")
            try Snapshot.render(JobsInterviewSheet(store: store, original: interview).environment(app),
                                size: CGSize(width: 500, height: 560), name: "mac-jobs-sheet-interview")
        }
        if let event = store.events.value?.first {
            await store.eventRead(event.id).refresh()
            store.go(to: JobsLocation(section: .events, route: .event(event.id)))
            try Snapshot.render(JobsScreen().environment(app), size: Self.size, name: "mac-jobs-event")
            try Snapshot.render(JobsEventSheet(store: store, original: event).environment(app),
                                size: CGSize(width: 500, height: 640), name: "mac-jobs-sheet-event")
        }
        try Snapshot.render(JobsApplicationSheet(store: store, original: nil).environment(app),
                            size: CGSize(width: 500, height: 640), name: "mac-jobs-sheet-add-application")
    }
}
