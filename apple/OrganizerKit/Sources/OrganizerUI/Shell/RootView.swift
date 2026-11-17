import OrganizerCore
import SwiftUI

/// The app shell: a sidebar with one entry per module from `ModuleRegistry`.
///
/// `.sidebarAdaptable` gives the Mac sidebar, which the user can customize (reorder, hide). Each
/// module's screen brings its own stack (`ModuleNavigationStack`). With no token set, the
/// first-launch sheet asks for the server address and a token.
public struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage("shell.selection") private var selection: ModuleID = .calendar
    @AppStorage("shell.customization") private var customization = TabViewCustomization()
    @State private var showsSetup = false

    public init() {}

    public var body: some View {
        tabs
            // A new server address or token rebuilds every screen and store.
            .id(app.generation)
            .onOpenURL(perform: open)
            .task {
                // `-launch.url lifeorganizer://…` on the command line opens a link at launch.
                if let raw = UserDefaults.standard.string(forKey: "launch.url"), let url = URL(string: raw) {
                    open(url)
                }
            }
            .onAppear { showsSetup = app.needsSetup }
            .sheet(isPresented: $showsSetup) {
                FirstLaunchView { showsSetup = false }
                    .environment(app)
            }
    }
}

extension RootView {
    /// Every module as a tab: the sidebar.
    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(ModuleRegistry.all) { module in
                Tab(module.label, systemImage: module.systemImage, value: module.id) {
                    module.screen
                }
                .customizationID("module.\(module.id.rawValue)")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewCustomization($customization)
    }

    /// Selects the link's module and hands the link to it.
    private func open(_ url: URL) {
        guard let link = DeepLink(url) else { return }
        selection = link.module
        app.deepLink = link
    }
}

#Preview {
    RootView().environment(AppEnvironment.preview())
}
