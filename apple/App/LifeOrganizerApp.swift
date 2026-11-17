import AppKit
import OrganizerCore
import OrganizerUI
import SwiftUI

/// The app entry. Everything but the in-app helper lives in OrganizerKit: the shell
/// (`RootView`), the module screens, the API client.
@main
struct LifeOrganizerApp: App {
    @State private var app = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: MacShell.mainWindowID) {
            RootView()
                .environment(app)
                .macMainWindowFrame()
                .task { InAppHelper.shared.launch(app: app) }
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .commands { OrganizerCommands() }

        Settings {
            TabView {
                Tab("General", systemImage: "gear") {
                    SettingsForm()
                }
                Tab("Helper", systemImage: "arrow.triangle.2.circlepath") {
                    HelperSettingsView(helper: InAppHelper.shared)
                }
            }
            .environment(app)
            .frame(width: 600, height: 680)
        }
    }
}

/// The go-to keys, and a clean stop for a running in-app helper when the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The helper writes to sockets; a peer that went away must fail that write, not end the app.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { GoKeySequence.install() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let helper = InAppHelper.shared
            guard helper.needsStop else { return .terminateNow }
            Task {
                await helper.stopForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }
}
