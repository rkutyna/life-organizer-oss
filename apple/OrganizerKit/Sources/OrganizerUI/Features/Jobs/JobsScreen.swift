import OrganizerAPI
import OrganizerCore
import SwiftUI

/// The Jobs module's root screen (the registry names this type; keep the name): the job tracker
/// in six sections (Pipeline, Applications, Leads, Contacts, Interviews, Events), a column of
/// sections beside the section's own stack. Records open on top of the section on show.
///
/// Deep links mirror the web's paths (see `JobsLocation`): `lifeorganizer://jobs`,
/// `jobs/applications/12`, `jobs/contacts/3`, `jobs/interviews/2`, `jobs/events?event=4`.
struct JobsScreen: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        JobsView(store: app.store { JobsStore(client: $0) })
    }
}

struct JobsView: View {
    @Bindable var store: JobsStore
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 190)
            Divider()
            ModuleNavigationStack(path: $store.path) {
                JobsSectionRoot(store: store, section: store.section)
                    .navigationTitle(store.section.title)
                    .navigationDestination(for: JobsRoute.self) { route in
                        JobsRouteView(store: store, route: route)
                    }
            }
            // A new section starts a fresh stack.
            .id(store.section)
        }
        .sheet(item: $store.sheet) { sheet in
            JobsSheetView(store: store, sheet: sheet)
        }
        .notices($store.notice)
        .task { await store.prepare() }
        .task(id: app.deepLink(for: .jobs)?.id) { open(app.deepLink(for: .jobs)) }
    }

    private var sidebar: some View {
        List(selection: Binding<JobsSection?>(
            get: { store.section },
            set: { if let section = $0 { store.section = section } }
        )) {
            Section("Jobs") {
                ForEach(JobsSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .badge(store.badge(section) ?? 0)
                        .tag(section)
                        .accessibilityIdentifier("jobs.section.\(section.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OpenInWebLink(path: store.section.webPath)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Handles a link to this module (see `JobsLocation`).
    private func open(_ link: DeepLink?) {
        guard let link else { return }
        defer { app.consume(link) }
        if let location = JobsLocation(link) {
            store.go(to: location)
        }
    }
}

/// A section's root view.
struct JobsSectionRoot: View {
    let store: JobsStore
    let section: JobsSection

    var body: some View {
        switch section {
        case .pipeline: JobsPipelineView(store: store)
        case .applications: JobsApplicationsList(store: store)
        case .leads: JobsLeadsList(store: store)
        case .contacts: JobsContactsList(store: store)
        case .interviews: JobsInterviewsList(store: store)
        case .events: JobsEventsList(store: store)
        }
    }
}

#Preview("Jobs") {
    JobsScreen().environment(AppEnvironment.preview())
}
